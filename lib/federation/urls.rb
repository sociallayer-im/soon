module Federation
  # Every federation URL is minted here and nowhere else (the pattern worth
  # keeping from nebula's lib/activity_pub/urls.rb). Actor ids are immutable
  # once a remote instance has cached them, so FEDERATION_HOST must be set to
  # the canonical host (app.sola.day) before anything federates.
  module Urls
    module_function

    def host
      ENV.fetch("FEDERATION_HOST") { URI.parse(ENV.fetch("WEB_URL", "https://app.sola.day")).host }
    end

    def scheme
      ENV.fetch("FEDERATION_SCHEME", "https")
    end

    def base_url
      "#{scheme}://#{host}"
    end

    def acct(actor)
      "#{actor.name}@#{host}"
    end

    # Actor ids live at root-level paths on the canonical host; the frontend
    # proxies them to this app (design/FEDERATION_PLAN.md §2.2).
    #
    # Keyed on the immutable id, NOT the handle. Handles are editable, and an
    # actor id is immutable in practice — the moment a peer caches it, changing
    # it orphans every follower, participation and delivery. Mastodon uses
    # /ap/users/<numeric id> for exactly this reason and lets webfinger map the
    # handle onto it; so do we. The handle still appears as preferredUsername
    # and in the human URL, both of which are allowed to change.
    def actor_url(actor)
      case actor
      when User then "#{base_url}/users/#{actor.id}"
      when Group then "#{base_url}/groups/#{actor.id}"
      else raise ArgumentError, "not a federated actor: #{actor.class}"
      end
    end

    # Resolves either form: the canonical id, or a handle (peers that cached a
    # handle URL before, and humans typing one, both still land).
    def find_user(key)
      User.find_by(id: key) || User.find_by(name: key)
    end

    def find_group(key)
      Group.find_by(id: key) || Group.find_by(name: key)
    end

    def key_id(actor)
      "#{actor_url(actor)}#main-key"
    end

    def inbox_url(actor) = "#{actor_url(actor)}/inbox"
    def outbox_url(actor) = "#{actor_url(actor)}/outbox"
    def followers_url(actor) = "#{actor_url(actor)}/followers"
    def following_url(actor) = "#{actor_url(actor)}/following"

    def shared_inbox_url
      "#{base_url}/inbox"
    end

    def instance_actor_url
      "#{base_url}/actor"
    end

    def instance_key_id
      "#{instance_actor_url}#main-key"
    end

    # AP object id — distinct from the human page URL, same as Mobilizon's
    # event.url vs frontend route split.
    def event_url(event)
      "#{base_url}/events/#{event.id}"
    end

    def event_html_url(event)
      "#{base_url}/event/detail/#{event.id}"
    end

    def activity_url(suffix)
      "#{base_url}/#{suffix.delete_prefix('/')}"
    end

    def local?(uri)
      URI.parse(uri).host == host
    rescue URI::Error
      false
    end
  end
end
