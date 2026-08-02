module Api
  module V1
    # The user-facing half of federation: resolve a remote handle, follow it,
    # and see/join the events it publishes. Ordinary JWT auth — this is the
    # app's own API, not protocol surface.
    class FederationDiscoveryController < Api::BaseController
      skip_before_action :authenticate!, only: [:events, :event]
      before_action :authenticate_optional!, only: [:events, :event]
      before_action :require_federation!

      # POST /api/v1/federation/resolve {acct: "user@host"} | {uri: "https://..."}
      def resolve
        actor =
          if params[:uri].present?
            Federation::ActorFetchService.fetch!(params[:uri])
          else
            Federation::WebfingerService.resolve!(params[:acct].to_s)
          end
        render json: actor_json(actor)
      rescue Federation::ActorFetchService::FetchError, Federation::WebfingerService::Error,
             Federation::HttpClient::Error => e
        render_error("could not resolve: #{e.message}", status: :unprocessable_entity)
      end

      # POST /api/v1/federation/follow {uri:}
      def follow
        actor = FedActor.find_by(uri: params[:uri]) || Federation::ActorFetchService.fetch!(params[:uri].to_s)
        return render_error("actor is blocked", status: :forbidden) if actor.blocked?
        f = Federation::OutboxService.follow(current_user, actor)
        render json: {state: f.state, actor: actor_json(actor)}, status: :created
      rescue Federation::ActorFetchService::FetchError, Federation::HttpClient::Error => e
        render_error("could not follow: #{e.message}", status: :unprocessable_entity)
      end

      # DELETE /api/v1/federation/follow?uri=
      def unfollow
        actor = FedActor.find_by(uri: params[:uri]) or return render_not_found
        Federation::OutboxService.unfollow(current_user, actor)
        head :no_content
      end

      # GET /api/v1/federation/following
      def following
        follows = FedFollow.outbound.where(local: current_user).includes(:fed_actor)
        render json: follows.map { |f| {state: f.state}.merge(actor_json(f.fed_actor)) }
      end

      # GET /api/v1/federation/events — mirrored remote events
      def events
        scope = FedEvent.listable.upcoming.includes(:fed_actor).order(:start_time).limit(50)
        render json: scope.map { |e| event_json(e) }
      end

      # GET /api/v1/federation/events/:id
      def event
        e = FedEvent.find_by(id: params[:id]) or return render_not_found
        render json: event_json(e, detail: true)
      end

      # POST /api/v1/federation/events/:id/join
      def join
        e = FedEvent.find_by(id: params[:id]) or return render_not_found
        return render_error("this event is not joinable from here") unless e.joinable?
        return render_error("set a username before federating") if current_user.name.blank?
        part = Federation::OutboxService.join(current_user, e, message: params[:message])
        return render_error("event origin has no inbox") if part.nil?
        render json: {status: part.status, event: event_json(e)}, status: :created
      end

      # DELETE /api/v1/federation/events/:id/join
      def leave
        e = FedEvent.find_by(id: params[:id]) or return render_not_found
        Federation::OutboxService.leave(current_user, e)
        head :no_content
      end

      private

      def require_federation!
        render_error("federation is disabled", status: :not_found) unless Federation.enabled?
      end

      def actor_json(actor)
        {
          uri: actor.uri, acct: actor.acct, domain: actor.domain,
          type: actor.actor_type, name: actor.name, summary: actor.summary,
          image_url: actor.icon_url
        }
      end

      def event_json(e, detail: false)
        base = {
          id: e.id, uri: e.uri, url: e.html_url, title: e.title,
          start_time: e.start_time, end_time: e.end_time, timezone: e.timezone,
          status: e.status, join_mode: e.join_mode,
          external_participation_url: e.external_participation_url,
          max_participant: e.max_participant, participant_count: e.participant_count,
          location: {name: e.location_name, address: e.address,
                     latitude: e.latitude, longitude: e.longitude}.compact,
          image_url: e.image_url, tags: e.tags,
          origin: e.fed_actor && {acct: e.fed_actor.acct, domain: e.fed_actor.domain,
                                  name: e.fed_actor.name}
        }
        base[:content] = e.content if detail
        base[:summary] = e.summary if detail
        if current_user
          part = FedParticipation.find_by(user: current_user, fed_event: e)
          base[:my_status] = part&.status
        end
        base
      end
    end
  end
end
