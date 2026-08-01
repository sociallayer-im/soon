require "test_helper"

# The sign/verify negative matrix from design/FEDERATION_TEST_PLAN.md §4.2/§4.3.
# Every rejection case pairs with an acceptance case (same request, minimally
# corrected) so a verifier that rejects everything cannot pass.
class Federation::HttpSignatureTest < ActiveSupport::TestCase
  SIG = Federation::HttpSignature

  setup do
    @key = OpenSSL::PKey::RSA.new(2048)
    @key_id = "https://remote.example/users/alice#main-key"
    @now = Time.utc(2026, 8, 2, 12, 0, 0)
  end

  def signed_post(body: '{"type":"Create"}', url: "https://app.sola.day/inbox", date: @now, key: @key)
    headers = SIG.sign(method: :post, url: url, key_id: @key_id, private_key: key.to_pem, body: body, date: date)
    [headers, body]
  end

  def verify(headers, body, method: :post, path: "/inbox", key: @key, now: @now)
    SIG.verify!(method: method, path: path, headers: headers, body: body,
                public_key_pem: key.public_key.to_pem, now: now)
  end

  # --- acceptance baseline -------------------------------------------------

  test "valid POST round-trip verifies" do
    headers, body = signed_post
    assert verify(headers, body)
  end

  test "valid GET round-trip verifies" do
    headers = SIG.sign(method: :get, url: "https://app.sola.day/users/x?page=1",
                       key_id: @key_id, private_key: @key.to_pem, date: @now)
    assert verify(headers, nil, method: :get, path: "/users/x?page=1")
  end

  test "verifier accepts request-target signed without the query string" do
    # sign over the bare path, verify against path-with-query (Mastodon's dual)
    headers = SIG.sign(method: :get, url: "https://app.sola.day/users/x",
                       key_id: @key_id, private_key: @key.to_pem, date: @now)
    assert verify(headers, nil, method: :get, path: "/users/x?page=1")
  end

  test "header lookup is case-insensitive" do
    headers, body = signed_post
    upcased = headers.transform_keys(&:upcase)
    assert verify(upcased, body)
  end

  # --- signing-string shape (SG matrix) ------------------------------------

  test "host omits default port 443" do
    headers = SIG.sign(method: :post, url: "https://mastodon.example:443/inbox",
                       key_id: @key_id, private_key: @key.to_pem, body: "x", date: @now)
    assert_equal "mastodon.example", headers["Host"]
  end

  test "host keeps a non-default port" do
    headers = SIG.sign(method: :post, url: "https://lab.example:4567/inbox",
                       key_id: @key_id, private_key: @key.to_pem, body: "x", date: @now)
    assert_equal "lab.example:4567", headers["Host"]
  end

  test "POST signs (request-target) host date digest" do
    headers, = signed_post
    params = SIG.parse_signature_header(headers["Signature"])
    assert_equal "(request-target) host date digest", params["headers"]
    assert_equal "rsa-sha256", params["algorithm"]
    assert_equal @key_id, params["keyId"]
  end

  test "digest is SHA-256 of the body, 32 bytes" do
    headers, body = signed_post
    encoded = headers["Digest"].delete_prefix("SHA-256=")
    assert_equal OpenSSL::Digest::SHA256.digest(body), Base64.decode64(encoded)
  end

  # --- parser robustness ---------------------------------------------------

  test "parses signature params when base64 contains commas-adjacent chars" do
    # regression for nebula's split(",") parser: build a header whose
    # signature value contains '+' '/' '=' and verify parsing stays intact
    headers, body = signed_post
    params = SIG.parse_signature_header(headers["Signature"])
    assert params["signature"].length > 300
    assert verify(headers, body)
  end

  test "missing Signature header raises" do
    headers, body = signed_post
    headers.delete("Signature")
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  test "signature header without keyId raises" do
    assert_raises(SIG::VerificationError) do
      SIG.parse_signature_header(%(algorithm="rsa-sha256",signature="abc"))
    end
  end

  # --- algorithm (SV-4, SV-5) ----------------------------------------------

  test "hs2019 is accepted (verified as rsa-sha256)" do
    headers, body = signed_post
    headers["Signature"] = headers["Signature"].sub("rsa-sha256", "hs2019")
    assert verify(headers, body)
  end

  test "rsa-sha1 is rejected" do
    headers, body = signed_post
    headers["Signature"] = headers["Signature"].sub("rsa-sha256", "rsa-sha1")
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  # --- strength requirements (SV-2 family) ---------------------------------

  test "POST without digest in signed headers is rejected even if signature is valid" do
    headers = SIG.sign(method: :get, url: "https://app.sola.day/inbox",
                       key_id: @key_id, private_key: @key.to_pem, date: @now)
    # a GET-shaped signature replayed as POST lacks digest coverage
    assert_raises(SIG::VerificationError) { verify(headers, "body", method: :post) }
  end

  test "GET without host in signed headers is rejected" do
    headers, body = signed_post
    headers["Signature"] = headers["Signature"].sub(
      %(headers="(request-target) host date digest"), %(headers="(request-target) date digest")
    )
    assert_raises(SIG::VerificationError) { verify(headers, body, method: :get) }
  end

  test "signature covering neither date nor (created) is rejected" do
    headers, body = signed_post
    headers["Signature"] = headers["Signature"].sub(
      %(headers="(request-target) host date digest"), %(headers="(request-target) host digest")
    )
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  # --- digest (SV-3, §4.4) --------------------------------------------------

  test "tampered body fails digest check" do
    headers, = signed_post
    err = assert_raises(SIG::VerificationError) { verify(headers, '{"type":"Delete"}') }
    assert_match(/digest/i, err.message)
  end

  test "digest header swapped for another valid body's digest fails" do
    headers, body = signed_post
    headers["Digest"] = SIG.digest_for("other body")
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  test "SHA-512 digest is rejected" do
    headers, body = signed_post
    headers["Digest"] = "SHA-512=#{Base64.strict_encode64(OpenSSL::Digest::SHA512.digest(body))}"
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  test "multi-value digest picks the SHA-256 entry" do
    headers, body = signed_post
    original = headers["Digest"]
    headers["Digest"] = "#{original}, SHA-512=#{Base64.strict_encode64(OpenSSL::Digest::SHA512.digest(body))}"
    # digest header participates in the signature, so re-sign with the combined value
    headers2 = SIG.sign(method: :post, url: "https://app.sola.day/inbox",
                        key_id: @key_id, private_key: @key.to_pem, body: body, date: @now)
    combined = "#{headers2['Digest']}, SHA-512=x"
    resigned = resign_with_digest(body, combined)
    assert verify(resigned, body)
  end

  test "lowercase sha-256 digest key is accepted" do
    headers, body = signed_post
    resigned = resign_with_digest(body, headers["Digest"].sub("SHA-256", "sha-256"))
    assert verify(resigned, body)
  end

  # --- time window (SV-9 boundary values) -----------------------------------

  test "date 59 minutes in the future passes, 61 minutes fails" do
    ok, body = signed_post(date: @now + 59.minutes)
    assert verify(ok, body)
    stale, body2 = signed_post(date: @now + 61.minutes)
    assert_raises(SIG::VerificationError) { verify(stale, body2) }
  end

  test "signature older than skew window fails" do
    headers, body = signed_post(date: @now - 2.hours)
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  test "unparseable Date header fails" do
    headers, body = signed_post
    headers["Date"] = "not-a-date"
    assert_raises(SIG::VerificationError) { verify(headers, body) }
  end

  # --- keys (SV-1 adjacent, SV-11) ------------------------------------------

  test "wrong public key fails verification" do
    headers, body = signed_post
    other = OpenSSL::PKey::RSA.new(2048)
    assert_raises(SIG::VerificationError) { verify(headers, body, key: other) }
  end

  test "keys below 2048 bits are rejected" do
    weak = OpenSSL::PKey::RSA.new(1024)
    headers, body = signed_post(key: weak)
    assert_raises(SIG::VerificationError) { verify(headers, body, key: weak) }
  end

  test "garbage public key raises VerificationError, not a crash" do
    headers, body = signed_post
    assert_raises(SIG::VerificationError) do
      SIG.verify!(method: :post, path: "/inbox", headers: headers, body: body,
                  public_key_pem: "not a pem", now: @now)
    end
  end

  private

  def resign_with_digest(body, digest_value)
    date = @now.httpdate
    signing = [
      "(request-target): post /inbox",
      "host: app.sola.day",
      "date: #{date}",
      "digest: #{digest_value}"
    ].join("\n")
    sig = Base64.strict_encode64(@key.sign(OpenSSL::Digest.new("SHA256"), signing))
    {
      "Host" => "app.sola.day", "Date" => date, "Digest" => digest_value,
      "Signature" => %(keyId="#{@key_id}",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="#{sig}")
    }
  end
end
