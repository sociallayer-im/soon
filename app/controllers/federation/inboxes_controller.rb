module Federation
  # POST /inbox and the per-actor inboxes. The gauntlet, in cost order —
  # each step rejects before the next spends anything
  # (design/FEDERATION_PLAN.md §2.6/§2.10):
  #   size cap → JSON parse → blocklist (keyId domain, BEFORE any key fetch)
  #   → rate limits → signature + digest + time window (refetch key once on
  #   failure) → payload-actor == signer → idempotency ledger → 202 + job.
  class InboxesController < BaseController
    MAX_BODY = 1.megabyte
    TYPE_LIMITS = {"Follow" => :follow, "Join" => :join, "Create" => :note}.freeze

    def create
      if request.content_length.to_i > MAX_BODY
        return reject(:payload_too_large, status: 413)
      end
      body = request.raw_post
      return reject(:payload_too_large, status: 413) if body.bytesize > MAX_BODY

      activity = parse_json(body) or return reject(:bad_json, status: 400)

      params_sig = parse_signature or return reject(:bad_signature_header, status: 401)
      key_id = params_sig["keyId"]
      @domain = URI.parse(key_id).host.to_s.downcase rescue nil
      return reject(:bad_key_id, status: 401) if @domain.blank?

      # governance before any outbound work
      return reject(:domain_blocked, status: 403) unless FedDomainPolicy.domain_allowed?(@domain)
      unless RateLimiter.allow?(:domain, @domain)
        response.headers["Retry-After"] = RateLimiter.retry_after(:domain).to_s
        return reject(:rate_limited_domain, status: 429)
      end

      fed_actor = verify_signature!(key_id, body) or return reject(:signature_invalid, status: 401)
      return reject(:actor_blocked, status: 403) if fed_actor.blocked?

      # signed identity is the identity; payload claims must match
      unless activity["actor"] == fed_actor.uri
        return reject(:actor_mismatch, status: 401)
      end

      unless actor_rate_ok?(fed_actor, activity["type"])
        response.headers["Retry-After"] = RateLimiter.retry_after(:actor).to_s
        return reject(:rate_limited_actor, status: 429)
      end

      return reject(:bad_activity_id, status: 400) unless valid_activity_id?(activity)

      FedDomainStat.record_inbound!(@domain)
      if FedInboundActivity.record!(uri: activity["id"], activity_type: activity["type"],
                                    fed_actor_id: fed_actor.id)
        InboundJob.perform_later(fed_actor.id, activity)
        Logging.log(:in, activity["type"], domain: @domain, status: "accepted")
      else
        Logging.log(:in, activity["type"], domain: @domain, status: "duplicate")
      end
      head :accepted
    end

    private

    def parse_json(body)
      json = JSON.parse(body)
      json.is_a?(Hash) ? json : nil
    rescue JSON::ParserError
      nil
    end

    def parse_signature
      HttpSignature.parse_signature_header(request.headers["Signature"])
    rescue HttpSignature::VerificationError
      nil
    end

    def verify_signature!(key_id, body)
      actor = ActorFetchService.resolve_key(key_id)
      verify_against(actor, body)
      actor
    rescue HttpSignature::VerificationError
      # the remote may have rotated keys: refetch once, then give up (KY-5)
      begin
        actor = ActorFetchService.resolve_key(key_id, refetch: true)
        verify_against(actor, body)
        actor
      rescue HttpSignature::VerificationError, ActorFetchService::FetchError, HttpClient::Error
        nil
      end
    rescue ActorFetchService::FetchError, HttpClient::Error
      nil
    end

    def verify_against(actor, body)
      HttpSignature.verify!(
        method: request.method, path: request.fullpath,
        headers: signature_headers, body: body,
        public_key_pem: actor.public_key_pem
      )
    end

    def signature_headers
      {
        "signature" => request.headers["Signature"],
        "host" => request.headers["Host"],
        "date" => request.headers["Date"],
        "digest" => request.headers["Digest"],
        "content-type" => request.headers["Content-Type"]
      }.compact
    end

    def actor_rate_ok?(fed_actor, type)
      return false unless RateLimiter.allow?(:actor, fed_actor.id)
      kind = TYPE_LIMITS[type]
      kind.nil? || RateLimiter.allow?(kind, fed_actor.id)
    end

    def valid_activity_id?(activity)
      activity["id"].is_a?(String) && activity["id"].start_with?("https://", "http://") &&
        activity["type"].is_a?(String)
    end

    def reject(reason, status:)
      FedDomainStat.record_inbound!(@domain, rejected: true) if @domain.present?
      Logging.log(:in, "reject", domain: @domain, status: reason, http: status)
      head status
    end
  end
end
