require "test_helper"

class FedInboundActivityTest < ActiveSupport::TestCase
  test "record! is first-write-wins (OO-1 idempotency base)" do
    uri = "https://remote.example/activities/#{SecureRandom.hex(6)}"
    assert FedInboundActivity.record!(uri: uri, activity_type: "Create")
    refute FedInboundActivity.record!(uri: uri, activity_type: "Create")
    assert_equal 1, FedInboundActivity.where(uri: uri).count
  end
end
