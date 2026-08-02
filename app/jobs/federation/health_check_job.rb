module Federation
  # The alert thresholds from design/FEDERATION_PLAN.md §2.9. There is no
  # metrics stack on this host, so an alert is a log line with a stable prefix
  # (`[fed-alert]`) that an operator can grep or a log drain can match — the
  # same channel everything else in this subsystem reports through.
  #
  # Thresholds are read per run, not frozen at boot, so they can be retuned
  # without a deploy. Each has a test that drives it over the line: a threshold
  # that has never fired is indistinguishable from one that cannot
  # (design/FEDERATION_TEST_PLAN.md §5.3).
  class HealthCheckJob < ApplicationJob
    queue_as :federation

    # A domain has to be sending a meaningful amount before its reject ratio
    # means anything — three bad requests is not an attack.
    REJECT_FLOOR = 20

    def perform
      return unless Federation.enabled?
      alerts = collect
      alerts.each { |a| Rails.logger.warn("[fed-alert] #{a}") }
      alerts
    end

    def collect
      [queue_depth_alert, oldest_pending_alert, mailer_delay_alert, *reject_ratio_alerts].compact
    end

    private

    def threshold(name, default)
      ENV.fetch("FEDERATION_ALERT_#{name}", default.to_s).to_f
    end

    def queue_depth_alert
      limit = threshold("QUEUE_DEPTH", 500).to_i
      depth = FedDelivery.where(status: %w[pending delivering]).count
      "queue_depth=#{depth} threshold=#{limit}" if depth > limit
    end

    def oldest_pending_alert
      limit = threshold("OLDEST_PENDING_S", 3600).to_i
      oldest = FedDelivery.where(status: "pending").minimum(:created_at)
      return nil if oldest.nil?
      age = (Time.current - oldest).to_i
      "oldest_pending_age_s=#{age} threshold=#{limit}" if age > limit
    end

    # Federation must never starve transactional mail — sign-in codes are the
    # reason this check exists.
    def mailer_delay_alert
      limit = threshold("MAILER_DELAY_S", 300).to_i
      delay = mailer_queue_delay
      return nil if delay.nil? || delay <= limit
      "mailer_queue_delay_s=#{delay} threshold=#{limit} " \
        "hint=federation may be starving transactional mail"
    end

    def reject_ratio_alerts
      limit = threshold("REJECT_RATIO", 0.5)
      FedDomainStat.where("inbound_rejected_count >= ?", REJECT_FLOOR).filter_map do |stat|
        total = stat.inbound_count + stat.inbound_rejected_count
        next if total.zero?
        ratio = stat.inbound_rejected_count.to_f / total
        next unless ratio > limit
        "domain=#{stat.domain} inbound_reject_ratio=#{ratio.round(2)} " \
          "rejected=#{stat.inbound_rejected_count} threshold=#{limit}"
      end
    end

    # Oldest queued mail that has not started yet. GoodJob keeps finished rows,
    # so only unfinished, unstarted ones count.
    def mailer_queue_delay
      scheduled = GoodJob::Job.where(queue_name: "mailers", finished_at: nil, performed_at: nil)
                              .minimum(:scheduled_at)
      scheduled && [(Time.current - scheduled).to_i, 0].max
    rescue StandardError
      nil # GoodJob's schema is not a hard dependency of the alerting path
    end
  end
end
