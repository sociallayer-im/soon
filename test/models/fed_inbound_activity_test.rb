require "test_helper"

class FedInboundActivityTest < ActiveSupport::TestCase
  test "record! is first-write-wins (OO-1 idempotency base)" do
    uri = "https://remote.example/activities/#{SecureRandom.hex(6)}"
    assert_equal :new, FedInboundActivity.record!(uri: uri, activity_type: "Create")
    assert_equal :duplicate, FedInboundActivity.record!(uri: uri, activity_type: "Create")
    assert_equal 1, FedInboundActivity.where(uri: uri).count
    assert_equal "received", FedInboundActivity.find_by(uri: uri).status
  end

  test "a redelivery of a failed activity is claimed for retry, exactly once" do
    uri = "https://remote.example/activities/#{SecureRandom.hex(6)}"
    FedInboundActivity.record!(uri: uri, activity_type: "Join")
    FedInboundActivity.mark!(uri, "failed")

    # the remote redelivers: the failed row is claimed and re-runs
    assert_equal :retry, FedInboundActivity.record!(uri: uri, activity_type: "Join")
    assert_equal "received", FedInboundActivity.find_by(uri: uri).status
    # a second concurrent redelivery finds it already claimed
    assert_equal :duplicate, FedInboundActivity.record!(uri: uri, activity_type: "Join")
  end

  test "a redelivery of a processed activity stays a duplicate" do
    uri = "https://remote.example/activities/#{SecureRandom.hex(6)}"
    FedInboundActivity.record!(uri: uri, activity_type: "Follow")
    FedInboundActivity.mark!(uri, "processed")
    assert_equal :duplicate, FedInboundActivity.record!(uri: uri, activity_type: "Follow")
    assert_equal "processed", FedInboundActivity.find_by(uri: uri).status
  end
end
