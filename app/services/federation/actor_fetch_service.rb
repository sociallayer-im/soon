module Federation
  # Fetches and caches remote actors. Validation is Mastodon's acceptance
  # rules run in reverse (INTEROP §2.2): body id must equal the fetched URI,
  # content-type must be AP, @context must include AS, inbox is mandatory.
  # GETs are signed with the instance actor so authorized-fetch peers answer.
  class ActorFetchService
    SUPPORTED_TYPES = %w[Person Group Organization Service Application].freeze
    AP_CONTENT_TYPES = ["application/activity+json", "application/ld+json"].freeze

    class FetchError < StandardError; end

    # key_id → [FedActor, public_key_pem]; refetch: true forces a refresh
    # (used once after a failed verification, KY-5 semantics).
    def self.resolve_key(key_id, refetch: false)
      actor_uri = key_id.split("#").first.delete_suffix("/publickey")
      actor = FedActor.find_by(key_id: key_id) || FedActor.find_by(uri: actor_uri)
      actor = fetch!(actor_uri) if actor.nil? || actor.public_key_pem.blank? || refetch
      raise FetchError, "no public key for #{key_id}" if actor.public_key_pem.blank?
      actor
    end

    def self.fetch!(uri)
      domain = URI.parse(uri).host.to_s.downcase
      raise FetchError, "domain #{domain} not allowed" unless FedDomainPolicy.domain_allowed?(domain)

      doc = signed_get(uri)
      validate!(doc, uri)
      upsert(doc, uri, domain)
    end

    def self.signed_get(uri)
      key = FedInstanceKey.current
      headers = HttpSignature.sign(method: :get, url: uri,
                                   key_id: Urls.instance_key_id, private_key: key.private_key)
      headers["Accept"] = "application/activity+json, application/ld+json"
      response = HttpClient.get(uri, headers: headers)
      raise FetchError, "HTTP #{response.status} fetching #{uri}" unless response.success?
      content_type = response.headers["content-type"].to_s
      unless AP_CONTENT_TYPES.any? { |t| content_type.include?(t) }
        raise FetchError, "non-AP content-type #{content_type}"
      end
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise FetchError, "unparseable actor document: #{e.message}"
    end

    def self.validate!(doc, uri)
      raise FetchError, "id #{doc['id']} != fetched uri #{uri}" unless doc["id"] == uri
      context = Array(doc["@context"]).flatten
      unless context.include?(JsonLd::AS) || doc["@context"] == JsonLd::AS
        raise FetchError, "missing activitystreams @context"
      end
      type = Array(doc["type"]).find { |t| SUPPORTED_TYPES.include?(t) }
      raise FetchError, "unsupported actor type #{doc['type']}" if type.nil?
      raise FetchError, "actor has no inbox" if doc["inbox"].blank?
    end

    def self.upsert(doc, uri, domain)
      key = doc["publicKey"] || {}
      actor = FedActor.find_or_initialize_by(uri: uri)
      actor.assign_attributes(
        domain: domain,
        actor_type: Array(doc["type"]).find { |t| SUPPORTED_TYPES.include?(t) },
        preferred_username: doc["preferredUsername"],
        name: doc["name"],
        summary: doc["summary"],
        icon_url: doc.dig("icon", "url"),
        inbox_url: doc["inbox"],
        shared_inbox_url: doc.dig("endpoints", "sharedInbox") || doc["sharedInbox"],
        outbox_url: doc["outbox"],
        followers_url: doc["followers"],
        public_key_pem: key["publicKeyPem"],
        key_id: key["id"],
        last_fetched_at: Time.current,
        raw: doc
      )
      actor.save!
      actor
    rescue ActiveRecord::RecordNotUnique
      FedActor.find_by!(uri: uri)
    end
  end
end
