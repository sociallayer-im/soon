require "test_helper"

# SSRF and URL validation (design/FEDERATION_TEST_PLAN.md SV-12 and §2.4
# resource rules). No live HTTP here — validate_url!/check_addresses! are
# pure. Transport behavior is exercised by the S2S harness (P2).
class Federation::HttpClientTest < ActiveSupport::TestCase
  CLIENT = Federation::HttpClient

  test "rejects non-https schemes by default" do
    assert_raises(CLIENT::SSRFError) { CLIENT.validate_url!("http://remote.example/inbox") }
    assert_raises(CLIENT::SSRFError) { CLIENT.validate_url!("ftp://remote.example/x") }
    assert_raises(CLIENT::SSRFError) { CLIENT.validate_url!("javascript:alert(1)") }
  end

  test "rejects private, loopback, link-local and mapped literals" do
    %w[
      https://127.0.0.1/inbox
      https://10.1.2.3/inbox
      https://192.168.1.1/inbox
      https://172.16.0.9/inbox
      https://169.254.169.254/latest/meta-data
      https://[::1]/inbox
      https://[fc00::1]/inbox
      https://[::ffff:127.0.0.1]/inbox
      https://100.64.0.1/inbox
    ].each do |url|
      assert_raises(CLIENT::SSRFError, "expected #{url} to be blocked") { CLIENT.validate_url!(url) }
    end
  end

  test "accepts a public literal" do
    assert_equal "1.1.1.1", CLIENT.validate_url!("https://1.1.1.1/inbox").host
  end

  test "invalid URL raises Error, missing host raises SSRFError" do
    assert_raises(CLIENT::Error) { CLIENT.validate_url!("https://exa mple.com/") }
    assert_raises(CLIENT::SSRFError) { CLIENT.validate_url!("https:///inbox") }
  end

  # Minimal fake transport: returns canned responses in order, records calls.
  FakeResponse = Struct.new(:status, :headers, :body, keyword_init: true)
  class FakeSession
    attr_reader :calls
    def initialize(responses) = (@responses = responses; @calls = [])
    def request(method, url, headers:, body: nil)
      @calls << {method: method, url: url, headers: headers}
      @responses.shift
    end
  end

  def with_fake_transport
    CLIENT.ssrf_protection = false
    yield
  ensure
    CLIENT.ssrf_protection = true
  end

  test "a POST is never redirected — the 3xx surfaces to the delivery layer" do
    fake = FakeSession.new([FakeResponse.new(status: 302,
      headers: {"location" => "https://elsewhere.example/inbox"}, body: "")])
    with_fake_transport do
      CLIENT.stub(:session, fake) do
        result = CLIENT.post("https://remote.example/inbox", body: "{}",
                             headers: {"Signature" => "sig"})
        assert_equal 302, result.status
      end
    end
    assert_equal 1, fake.calls.size, "must not follow the redirect"
  end

  test "a GET follows a cross-host redirect but strips the signed headers" do
    fake = FakeSession.new([
      FakeResponse.new(status: 301, headers: {"location" => "https://other.example/actor"}, body: ""),
      FakeResponse.new(status: 200, headers: {}, body: "{}")
    ])
    with_fake_transport do
      CLIENT.stub(:session, fake) do
        result = CLIENT.get("https://remote.example/actor",
                            headers: {"Signature" => "sig", "Date" => "now", "Accept" => "application/activity+json"})
        assert_equal 200, result.status
      end
    end
    assert_equal 2, fake.calls.size
    second = fake.calls.last
    assert_equal "https://other.example/actor", second[:url]
    refute second[:headers].key?("Signature"), "signature must not cross hosts"
    refute second[:headers].key?("Date")
    assert_equal "application/activity+json", second[:headers]["Accept"]
  end

  test "a GET keeps its headers on a same-host redirect" do
    fake = FakeSession.new([
      FakeResponse.new(status: 302, headers: {"location" => "/actor2"}, body: ""),
      FakeResponse.new(status: 200, headers: {}, body: "{}")
    ])
    with_fake_transport do
      CLIENT.stub(:session, fake) do
        CLIENT.get("https://remote.example/actor", headers: {"Signature" => "sig"})
      end
    end
    assert_equal "sig", fake.calls.last[:headers]["Signature"]
  end

  test "ssrf_protection can be disabled for the test harness only" do
    CLIENT.ssrf_protection = false
    CLIENT.allowed_schemes = %w[https http]
    assert_equal "127.0.0.1", CLIENT.validate_url!("http://127.0.0.1:4567/inbox").host
  ensure
    CLIENT.ssrf_protection = true
    CLIENT.allowed_schemes = %w[https]
  end
end
