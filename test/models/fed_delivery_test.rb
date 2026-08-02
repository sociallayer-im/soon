require "test_helper"

# Retry-vs-permanent semantics (design/FEDERATION_TEST_PLAN.md §2.1 DL matrix,
# static part — the full state machine runs against the sweeper in P2).
class FedDeliveryTest < ActiveSupport::TestCase
  def build_delivery(**attrs)
    FedDelivery.create!({payload: {"type" => "Create"}, sender_type: "Group",
                         sender_id: "x", inbox_url: "https://remote.example/inbox"}.merge(attrs))
  end

  test "2xx marks delivered and clears the error" do
    d = build_delivery(last_error: "old")
    d.mark_result!(202)
    assert_equal "delivered", d.status
    assert_nil d.last_error
  end

  test "retryable statuses reschedule with growing backoff" do
    [nil, 401, 408, 429, 500, 503].each do |code|
      d = build_delivery(attempts: 2)
      d.mark_result!(code, error: code ? nil : "timeout")
      assert_equal "pending", d.status, "expected #{code.inspect} to retry"
      assert d.next_attempt_at > Time.current + 15.seconds
    end
  end

  test "permanent statuses stop retrying" do
    [400, 403, 404, 410, 413, 422, 501].each do |code|
      d = build_delivery
      d.mark_result!(code)
      assert_equal "failed_permanent", d.status, "expected #{code} to be permanent"
    end
  end

  test "retries exhaust at MAX_ATTEMPTS" do
    d = build_delivery(attempts: FedDelivery::MAX_ATTEMPTS)
    d.mark_result!(500)
    assert_equal "failed_permanent", d.status
    assert_match(/exhausted/, d.last_error)
  end

  test "3xx is permanent — a signed POST is never replayed at a redirect target" do
    [301, 302, 303, 307, 308].each do |code|
      d = build_delivery
      d.mark_result!(code)
      assert_equal "failed_permanent", d.status, "expected #{code} to be permanent"
    end
  end

  test "Retry-After delays the next attempt at least that long" do
    d = build_delivery(attempts: 1)
    d.mark_result!(429, retry_after: "600")
    assert_equal "pending", d.status
    assert d.next_attempt_at >= Time.current + 590.seconds, "must honour Retry-After: 600"
  end

  test "Retry-After accepts HTTP-date and is clamped to a day" do
    assert_in_delta 300, FedDelivery.parse_retry_after((Time.current + 300).httpdate), 3
    assert_equal 86_400, FedDelivery.parse_retry_after("999999999")
    assert_equal 0, FedDelivery.parse_retry_after((Time.current - 60).httpdate)
    assert_nil FedDelivery.parse_retry_after("not a date")
    assert_nil FedDelivery.parse_retry_after(nil)
  end

  test "a short Retry-After never undercuts our own backoff" do
    d = build_delivery(attempts: 5) # backoff ≥ 640s
    d.mark_result!(429, retry_after: "1")
    assert d.next_attempt_at >= Time.current + 600.seconds
  end

  test "due scope picks only ripe pending rows" do
    ripe = build_delivery
    later = build_delivery(next_attempt_at: 1.hour.from_now)
    done = build_delivery(status: "delivered")
    ids = FedDelivery.due.pluck(:id)
    assert_includes ids, ripe.id
    refute_includes ids, later.id
    refute_includes ids, done.id
  end

  test "backoff curve is monotonic in attempts" do
    lows = FedDelivery.new(attempts: 1)
    highs = FedDelivery.new(attempts: 8)
    assert highs.backoff_seconds > lows.backoff_seconds
  end
end
