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
      outcome = FedInboundActivity.record!(uri: activity["id"], activity_type: activity["type"],
                                           fed_actor_id: fed_actor.id)
      if outcome == :duplicate
        Logging.log(:in, activity["type"], domain: @domain, status: "duplicate")
      else
        begin
          InboundJob.perform_later(fed_actor.id, activity)
        rescue StandardError => e
          # Ledger row written but no job — mark failed so the remote's
          # redelivery re-runs it instead of hitting the duplicate branch,
          # and 500 so the remote does redeliver.
          FedInboundActivity.mark!(activity["id"], "failed")
          Logging.log(:in, activity["type"], domain: @domain, status: "enqueue_failed", error: e.message)
          return head :internal_server_error
        end
        Logging.log(:in, activity["type"], domain: @domain, status: outcome == :retry ? "retried" : "accepted")
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
      error = nil
      candidate_hosts.each do |host|
        begin
          return HttpSignature.verify!(
            method: request.method, path: request.fullpath,
            headers: signature_headers.merge("host" => host), body: body,
            public_key_pem: actor.public_key_pem
          )
        rescue HttpSignature::VerificationError => e
          error = e
        end
      end
      raise error || HttpSignature::VerificationError.new("no host candidate verified")
    end

    # The sender signs the host it addressed — always the canonical federation
    # host, since that is where every actor URL lives. But the canonical host
    # proxies these paths to this app, and a proxy rewrites Host to its
    # upstream target, so by the time the request lands here the signed value
    # is gone. Try both what we received and the canonical host.
    #
    # X-Forwarded-Host is deliberately NOT consulted: it is attacker-controlled,
    # and trusting it would let a request signed for some other instance be
    # replayed into this inbox.
    def candidate_hosts
      [request.headers["Host"], Urls.host].compact.uniq
    end

    # Every request header, not a fixed subset — the signature may legitimately
    # cover headers we do not enumerate (Mastodon signs everything except
    # User-Agent/Accept/Accept-Encoding, which includes Content-Type and
    # Collection-Synchronization), and a signed-but-missing header fails
    # verification.
    def signature_headers
      request.headers.each_with_object({}) do |(key, value), acc|
        next unless value.is_a?(String)
        if key.start_with?("HTTP_")
          acc[key.delete_prefix("HTTP_").tr("_", "-").downcase] = value
        elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
          acc[key.tr("_", "-").downcase] = value
        end
      end
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
