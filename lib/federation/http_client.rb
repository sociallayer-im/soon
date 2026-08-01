require "resolv"
require "ipaddr"

module Federation
  # Outbound HTTP for federation: hard timeouts, ≤3 redirects, 1 MB response
  # cap, and SSRF protection — remote-supplied URLs (actor ids, keyIds,
  # inboxes) must never reach private address space. Neither reference
  # prototype guarded this; nebula's fetch_actor follows any http* URL.
  module HttpClient
    class Error < StandardError; end
    class SSRFError < Error; end
    class ResponseTooLarge < Error; end

    CONNECT_TIMEOUT = 5
    OPERATION_TIMEOUT = 10
    MAX_REDIRECTS = 3
    MAX_BODY = 1.megabyte

    BLOCKED_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::1/128 fc00::/7 fe80::/10 ::ffff:0:0/96
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    # Tests and the S2S harness talk to 127.0.0.1 mocks; production never
    # flips this.
    mattr_accessor :ssrf_protection, default: true
    mattr_accessor :allowed_schemes, default: %w[https]

    module_function

    def get(url, headers: {})
      request(:get, url, headers: headers)
    end

    def post(url, body:, headers: {})
      request(:post, url, headers: headers, body: body)
    end

    def request(method, url, headers: {}, body: nil, redirects_left: MAX_REDIRECTS)
      uri = validate_url!(url)

      response = session.request(method, uri.to_s, headers: headers, body: body)
      raise Error, "transport error: #{response.error.message}" if response.is_a?(HTTPX::ErrorResponse)

      if [301, 302, 303, 307, 308].include?(response.status)
        raise Error, "too many redirects" if redirects_left.zero?
        location = response.headers["location"] or raise Error, "redirect without location"
        return request(method, URI.join(uri, location).to_s,
                       headers: headers, body: body, redirects_left: redirects_left - 1)
      end

      if response.headers["content-length"].to_i > MAX_BODY
        raise ResponseTooLarge, "declared #{response.headers['content-length']} bytes"
      end
      payload = response.body.to_s
      raise ResponseTooLarge, "body #{payload.bytesize} bytes" if payload.bytesize > MAX_BODY

      Result.new(status: response.status, headers: response.headers.to_h, body: payload)
    end

    Result = Struct.new(:status, :headers, :body, keyword_init: true) do
      def success? = (200..299).cover?(status)
    end

    def validate_url!(url)
      uri = URI.parse(url)
      unless allowed_schemes.include?(uri.scheme)
        raise SSRFError, "scheme #{uri.scheme.inspect} not allowed"
      end
      raise SSRFError, "no host in #{url}" if uri.host.blank?
      check_addresses!(uri.host) if ssrf_protection
      uri
    rescue URI::Error => e
      raise Error, "invalid URL: #{e.message}"
    end

    # Every resolved address must be public. Resolution here and connection in
    # httpx race in theory (DNS rebinding); acceptable for now — Mastodon's
    # own Request goes further with a socket-level guard, revisit if needed.
    def check_addresses!(host)
      addresses =
        begin
          [IPAddr.new(host)]
        rescue IPAddr::InvalidAddressError
          Resolv::DNS.open { |dns|
            dns.getaddresses(host).map { |a| IPAddr.new(a.to_s) }
          }
        end
      raise SSRFError, "#{host} did not resolve" if addresses.empty?
      addresses.each do |addr|
        if BLOCKED_RANGES.any? { |range| range.include?(addr) }
          raise SSRFError, "#{host} resolves to blocked address #{addr}"
        end
      end
    end

    def session
      HTTPX.with(
        timeout: {connect_timeout: CONNECT_TIMEOUT, operation_timeout: OPERATION_TIMEOUT},
        headers: {"user-agent" => "sola-federation (+#{Federation::Urls.base_url})"}
      )
    end
  end
end
