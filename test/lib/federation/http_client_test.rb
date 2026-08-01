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

  test "ssrf_protection can be disabled for the test harness only" do
    CLIENT.ssrf_protection = false
    CLIENT.allowed_schemes = %w[https http]
    assert_equal "127.0.0.1", CLIENT.validate_url!("http://127.0.0.1:4567/inbox").host
  ensure
    CLIENT.ssrf_protection = true
    CLIENT.allowed_schemes = %w[https]
  end
end
