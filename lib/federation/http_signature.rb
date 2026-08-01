require "openssl"
require "base64"
require "uri"

module Federation
  # draft-cavage HTTP signatures, rsa-sha256 — sign and verify.
  #
  # The verify rules are copied from Mastodon's app/lib/signed_request.rb, the
  # de-facto oracle (design/FEDERATION_INTEROP_VERIFICATION.md §1): strength
  # requirements (POST must sign digest, GET must sign host, date or (created)
  # always), SHA-256-only digest that must decode to 32 bytes, ±1h clock skew,
  # and signed-string reconstruction tried both with and without the query
  # string. The sign side matches what Mastodon/Mobilizon verify — notably the
  # host header never includes a default port (nebula got this wrong and every
  # HTTPS delivery to Mastodon failed).
  module HttpSignature
    class Error < StandardError; end
    class VerificationError < Error; end

    CLOCK_SKEW = 1.hour
    EXPIRES_LIMIT = 12.hours
    ALGORITHMS = ["rsa-sha256", "hs2019", nil].freeze
    MIN_KEY_BITS = 2048

    module_function

    # Returns the headers to send: Host, Date, Digest (when body), Signature.
    def sign(method:, url:, key_id:, private_key:, body: nil, date: Time.now.utc)
      uri = URI.parse(url)
      host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      target_path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      headers = {
        "Host" => host,
        "Date" => date.httpdate
      }
      headers["Digest"] = digest_for(body) if body

      signed_names = ["(request-target)", "host", "date"]
      signed_names << "digest" if body

      signing_string = signed_names.map { |name|
        if name == "(request-target)"
          "(request-target): #{method.to_s.downcase} #{target_path}"
        else
          "#{name}: #{headers[name.split('-').map(&:capitalize).join('-')]}"
        end
      }.join("\n")

      signature = Base64.strict_encode64(
        OpenSSL::PKey::RSA.new(private_key).sign(OpenSSL::Digest.new("SHA256"), signing_string)
      )
      headers["Signature"] =
        %(keyId="#{key_id}",algorithm="rsa-sha256",headers="#{signed_names.join(' ')}",signature="#{signature}")
      headers
    end

    def digest_for(body)
      "SHA-256=#{Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(body.to_s))}"
    end

    # Parses the Signature header without splitting on commas inside the
    # base64 value (nebula's split(",") bug). Quoted values delimit safely.
    def parse_signature_header(header)
      raise VerificationError, "missing Signature header" if header.blank?
      params = header.scan(/([a-zA-Z]+)="([^"]*)"/).to_h
      raise VerificationError, "signature header missing keyId" if params["keyId"].blank?
      raise VerificationError, "signature header missing signature" if params["signature"].blank?
      params
    end

    # headers: a Hash of request headers (case-insensitive lookup handled
    # here). Raises VerificationError with the reason; returns true.
    def verify!(method:, path:, headers:, body:, public_key_pem:, now: Time.now.utc)
      headers = headers.transform_keys { |k| k.to_s.downcase }
      params = parse_signature_header(headers["signature"])

      unless ALGORITHMS.include?(params["algorithm"])
        raise VerificationError, "unsupported algorithm #{params['algorithm']} (only rsa-sha256 and hs2019)"
      end

      signed_names = (params["headers"] || "date").downcase.split(/\s+/)
      check_strength!(method, signed_names)
      check_time_window!(headers, params, now)
      check_digest!(headers, body) if signed_names.include?("digest")

      key = OpenSSL::PKey::RSA.new(public_key_pem)
      raise VerificationError, "key below #{MIN_KEY_BITS} bits" if key.n.num_bits < MIN_KEY_BITS
      signature = Base64.decode64(params["signature"])

      # Mastodon's own senders historically disagreed on whether the query
      # string belongs in (request-target); its verifier accepts both, so
      # ours does too.
      candidate_paths(path).each do |candidate|
        signing_string = signed_names.map { |name|
          if name == "(request-target)"
            "(request-target): #{method.to_s.downcase} #{candidate}"
          elsif name == "(created)"
            "(created): #{params['created']}"
          elsif name == "(expires)"
            "(expires): #{params['expires']}"
          else
            raise VerificationError, "signed header #{name} absent from request" unless headers.key?(name)
            "#{name}: #{headers[name]}"
          end
        }.join("\n")
        return true if key.verify(OpenSSL::Digest.new("SHA256"), signature, signing_string)
      end
      raise VerificationError, "signature does not match"
    rescue OpenSSL::PKey::PKeyError => e
      raise VerificationError, "unparseable public key: #{e.message}"
    end

    def candidate_paths(path)
      base = path.split("?").first
      path == base ? [path] : [path, base]
    end

    # Mastodon signed_request.rb:54-59.
    def check_strength!(method, signed_names)
      unless signed_names.include?("date") || signed_names.include?("(created)")
        raise VerificationError, "date or (created) must be signed"
      end
      unless signed_names.include?("(request-target)") || signed_names.include?("digest")
        raise VerificationError, "(request-target) or digest must be signed"
      end
      if method.to_s.casecmp("get").zero? && !signed_names.include?("host")
        raise VerificationError, "GET requests must sign host"
      end
      if method.to_s.casecmp("post").zero? && !signed_names.include?("digest")
        raise VerificationError, "POST requests must sign digest"
      end
    end

    def check_time_window!(headers, params, now)
      created =
        if params["created"].present?
          Time.at(params["created"].to_i).utc
        elsif headers["date"].present?
          begin
            Time.httpdate(headers["date"]).utc
          rescue ArgumentError
            raise VerificationError, "unparseable Date header"
          end
        else
          raise VerificationError, "no Date header or (created)"
        end

      expires = params["expires"].present? ? Time.at(params["expires"].to_i).utc : created + 5.minutes
      expires = [expires, created + EXPIRES_LIMIT].min

      raise VerificationError, "signed too far in the future" if created > now + CLOCK_SKEW
      raise VerificationError, "signature expired" if expires < now - CLOCK_SKEW
      true
    end

    def check_digest!(headers, body)
      raw = headers["digest"]
      raise VerificationError, "digest signed but header missing" if raw.blank?
      entry = raw.split(",").map(&:strip).find { |v| v.downcase.start_with?("sha-256=") }
      raise VerificationError, "digest is not SHA-256" if entry.nil?
      encoded = entry.split("=", 2).last
      decoded = Base64.decode64(encoded)
      raise VerificationError, "digest does not decode to 32 bytes" unless decoded.bytesize == 32
      actual = OpenSSL::Digest::SHA256.digest(body.to_s)
      unless ActiveSupport::SecurityUtils.secure_compare(decoded, actual)
        raise VerificationError, "digest does not match body"
      end
      true
    end
  end
end
