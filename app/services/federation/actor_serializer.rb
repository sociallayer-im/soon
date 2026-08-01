module Federation
  # AS2 actor documents for local users/groups and the instance actor.
  # Field set follows what Mastodon's ProcessAccountService actually consumes
  # and what Mobilizon's Converter.Actor expects — nothing speculative.
  class ActorSerializer
    def self.user(user) = new(user, type: "Person").as_ap
    def self.group(group) = new(group, type: "Group").as_ap

    def initialize(actor, type:)
      @actor = actor
      @type = type
    end

    def as_ap
      @actor.ensure_federation_keys!
      base = Urls.actor_url(@actor)
      doc = {
        "@context" => JsonLd.actor_context,
        "id" => base,
        "type" => @type,
        "preferredUsername" => @actor.name,
        "name" => @actor.nickname.presence || @actor.name,
        "summary" => sanitized_bio,
        "url" => html_url,
        "inbox" => Urls.inbox_url(@actor),
        "outbox" => Urls.outbox_url(@actor),
        "followers" => Urls.followers_url(@actor),
        "following" => Urls.following_url(@actor),
        "endpoints" => {"sharedInbox" => Urls.shared_inbox_url},
        "publicKey" => {
          "id" => Urls.key_id(@actor),
          "owner" => base,
          "publicKeyPem" => @actor.fed_public_key
        },
        "manuallyApprovesFollowers" => false,
        "discoverable" => true,
        "published" => @actor.created_at.utc.iso8601
      }
      doc["icon"] = {"type" => "Image", "url" => @actor.image_url} if @actor.image_url.present?
      doc["memberCount"] = @actor.memberships_count if @type == "Group"
      doc
    end

    def self.instance
      key = FedInstanceKey.current
      base = Urls.instance_actor_url
      {
        "@context" => JsonLd.actor_context,
        "id" => base,
        "type" => "Application",
        "preferredUsername" => Urls.host,
        "name" => "sola instance actor",
        "inbox" => Urls.shared_inbox_url,
        "outbox" => "#{base}/outbox",
        "endpoints" => {"sharedInbox" => Urls.shared_inbox_url},
        "publicKey" => {
          "id" => Urls.instance_key_id,
          "owner" => base,
          "publicKeyPem" => key.public_key
        },
        "manuallyApprovesFollowers" => true,
        "url" => web_url
      }
    end

    def self.web_url
      ENV.fetch("WEB_URL", "https://app.sola.day")
    end

    private

    def sanitized_bio
      return "" if @actor.bio.blank?
      ActionController::Base.helpers.sanitize(@actor.bio)
    end

    def html_url
      case @actor
      when User then "#{self.class.web_url}/profile/#{@actor.name}"
      when Group then "#{self.class.web_url}/group/#{@actor.name}"
      end
    end
  end
end
