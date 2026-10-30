require "test_helper"
class Api::V1::CreationConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "two concurrent creates with the same key commit one group" do
    user = create_user
    name = "parallel-#{unique_suffix}"
    payload = {group: {name: name}, idempotency_key: "create_concurrent_#{unique_suffix}"}
    headers = auth_headers(user)
    get "/api/v1/groups", headers: headers
    assert_response :success
    ready = Queue.new
    start = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          session = ActionDispatch::Integration::Session.new(Rails.application)
          ready << true
          start.pop
          session.post "/api/v1/groups", params: payload.deep_dup, headers: headers.dup, as: :json
          [session.response.status, session.response.parsed_body]
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = workers.map(&:value)
    assert_equal [201,201], results.map(&:first), results.map { |status,body| [status, body.is_a?(Hash) ? body["error"] : body.at_css("#exception-message-for-copy")&.text] }.inspect
    assert_equal 1, results.map { |r| r[1]["id"] }.uniq.length
    assert_equal 1, Group.where(name: name).count
  ensure
    Group.where(name: name).find_each(&:destroy!) if name
    user&.destroy!
  end
end
