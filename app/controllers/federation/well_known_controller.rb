module Federation
  class WellKnownController < BaseController
    # Dots are allowed in the name because the instance actor's username is the
    # host itself, mirroring how Mastodon addresses instance actors.
    ACCT_RE = /\Aacct:(?<name>[a-z0-9_.\-]+)@(?<host>[a-z0-9_.\-:]+)\z/i

    # GET /.well-known/webfinger?resource=acct:name@host
    # Contract details are Mastodon's (INTEROP §2.1): exact self-link type
    # string, subject that loops back, 404 for unknowns, 400 for no resource.
    def webfinger
      resource = params[:resource].to_s
      return render(json: {error: "resource required"}, status: :bad_request) if resource.blank?

      actor = resolve_resource(resource)
      return head :not_found if actor.nil?
      return render_instance_actor_finger if actor == :instance

      actor_url = Urls.actor_url(actor)
      response.headers["Cache-Control"] = "public, max-age=300"
      render json: {
        subject: "acct:#{Urls.acct(actor)}",
        aliases: [actor_url],
        links: [
          {rel: "self", type: "application/activity+json", href: actor_url},
          {rel: "http://webfinger.net/rel/profile-page/", type: "text/html", href: profile_url(actor)},
          {rel: "http://ostatus.org/schema/1.0/subscribe", template: "#{web_url}/interact?uri={uri}"}
        ]
      }, content_type: "application/jrd+json"
    end

    # GET /.well-known/host-meta — XRD pointing at webfinger (Mastodon's
    # fallback path when webfinger 404s).
    def host_meta
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
          <Link rel="lrdd" template="#{Urls.base_url}/.well-known/webfinger?resource={uri}"/>
        </XRD>
      XML
      render xml: xml, content_type: "application/xrd+xml"
    end

    # GET /.well-known/nodeinfo
    def nodeinfo_discovery
      render json: {
        links: [{rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                 href: "#{Urls.base_url}/nodeinfo/2.0"}]
      }
    end

    # GET /nodeinfo/2.0
    def nodeinfo
      counts = Rails.cache.fetch("federation/nodeinfo_counts", expires_in: 30.minutes) do
        {users: User.where(active: true).count,
         posts: Event.where(status: "published", visibility: "public").count}
      end
      render json: {
        version: "2.0",
        software: {name: "sola", version: "1.0.0"},
        protocols: ["activitypub"],
        services: {inbound: [], outbound: []},
        openRegistrations: true,
        usage: {users: {total: counts[:users]}, localPosts: counts[:posts]},
        metadata: {nodeName: "Social Layer"}
      }
    end

    private

    # The instance actor signs our outbound fetches. Under authorized-fetch
    # Mastodon verifies that signer by webfingering
    # `acct:<preferredUsername>@<host of the actor id>` and requiring it to loop
    # back — so this endpoint has to answer for the instance actor, whose
    # username is the host itself. Without it, every signed GET is 401 and no
    # secure-mode instance can read anything of ours.
    def render_instance_actor_finger
      url = Urls.instance_actor_url
      response.headers["Cache-Control"] = "public, max-age=300"
      render json: {
        subject: "acct:#{Urls.host}@#{Urls.host}",
        aliases: [url],
        links: [{rel: "self", type: "application/activity+json", href: url}]
      }, content_type: "application/jrd+json"
    end

    def resolve_resource(resource)
      if (m = resource.match(ACCT_RE))
        return nil unless host_matches?(m[:host])
        return :instance if m[:name].casecmp(Urls.host).zero?
        find_actor(m[:name])
      elsif resource.start_with?("http://", "https://")
        # URL-form lookup (Mobilizon sends these too, WF-7)
        return nil unless Urls.local?(resource)
        path = URI.parse(resource).path
        case path
        when "/actor" then :instance
        when %r{\A/users/(?<name>[a-z0-9_]+)\z} then User.find_by(name: Regexp.last_match[:name])
        when %r{\A/groups/(?<name>[a-z0-9_-]+)\z} then Group.find_by(name: Regexp.last_match[:name])
        end
      end
    end

    def host_matches?(host)
      host == Urls.host || host == "#{Urls.host}:443"
    end

    # users and groups share the acct namespace; user wins on collision
    # (documented in FEDERATION_PLAN §2.3).
    def find_actor(name)
      User.find_by(name: name) || Group.find_by(name: name)
    end

    def profile_url(actor)
      base = web_url
      actor.is_a?(User) ? "#{base}/profile/#{actor.name}" : "#{base}/group/#{actor.name}"
    end
  end
end
