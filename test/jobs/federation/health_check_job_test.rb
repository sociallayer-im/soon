require "test_helper"

# design/FEDERATION_TEST_PLAN.md §5.3: every threshold gets a scenario that
# drives it over the line. A threshold that has never fired is
# indistinguishable from one that cannot.
class Federation::HealthCheckJobTest < ActiveSupport::TestCase
  setup { ENV["FEDERATION_ENABLED"] = "true" }

  teardown do
    ENV.delete("FEDERATION_ENABLED")
    ENV.keys.grep(/\AFEDERATION_ALERT_/).each { |k| ENV.delete(k) }
  end

  def delivery(**attrs)
    FedDelivery.create!({payload: {"type" => "Create"}, sender_type: "Group",
                         sender_id: "x", inbox_url: "https://a.example/inbox"}.merge(attrs))
  end

  def alerts = Federation::HealthCheckJob.new.collect.join(" | ")

  test "a healthy queue produces no alerts" do
    3.times { delivery }
    assert_empty Federation::HealthCheckJob.new.collect
  end

  test "queue depth over the threshold alerts" do
    ENV["FEDERATION_ALERT_QUEUE_DEPTH"] = "2"
    3.times { delivery }
    assert_match(/queue_depth=3 threshold=2/, alerts)
  end

  test "a pending row older than the threshold alerts" do
    ENV["FEDERATION_ALERT_OLDEST_PENDING_S"] = "60"
    delivery.update_columns(created_at: 10.minutes.ago)
    assert_match(/oldest_pending_age_s=\d+ threshold=60/, alerts)
  end

  test "a domain rejecting most of what it sends alerts" do
    FedDomainStat.for("noisy.example").update!(inbound_count: 2, inbound_rejected_count: 40)
    assert_match(/domain=noisy\.example inbound_reject_ratio=0\.95/, alerts)
  end

  test "a domain below the volume floor never alerts, however bad its ratio" do
    FedDomainStat.for("quiet.example").update!(inbound_count: 0, inbound_rejected_count: 3)
    refute_match(/quiet\.example/, alerts)
  end

  test "mail queued behind federation alerts, naming the risk" do
    ENV["FEDERATION_ALERT_MAILER_DELAY_S"] = "60"
    GoodJob::Job.create!(queue_name: "mailers", scheduled_at: 10.minutes.ago,
                         active_job_id: SecureRandom.uuid, job_class: "MailDeliveryJob",
                         serialized_params: {})
    assert_match(/mailer_queue_delay_s=\d+ .*starving transactional mail/, alerts)
  end

  test "alerts go out on the [fed-alert] channel" do
    ENV["FEDERATION_ALERT_QUEUE_DEPTH"] = "0"
    delivery
    logged = []
    Rails.logger.stub(:warn, ->(msg) { logged << msg }) do
      Federation::HealthCheckJob.new.perform
    end
    assert logged.any? { |l| l.start_with?("[fed-alert]") },
           "expected a [fed-alert] line, got #{logged.inspect}"
  end

  test "the job is inert while federation is disabled" do
    ENV.delete("FEDERATION_ENABLED")
    ENV["FEDERATION_ALERT_QUEUE_DEPTH"] = "0"
    delivery
    assert_nil Federation::HealthCheckJob.new.perform
  end
end
