module Federation
  class ActorsController < BaseController
    # GET /users/:handle
    def user
      actor = Urls.find_user(params[:handle]) or return head(:not_found)
      return redirect_to("#{web_url}/profile/#{actor.name}", allow_other_host: true) unless ap_request?
      render_ap ActorSerializer.user(actor)
    end

    # GET /groups/:handle
    def group
      actor = Urls.find_group(params[:handle]) or return head(:not_found)
      return redirect_to("#{web_url}/group/#{actor.name}", allow_other_host: true) unless ap_request?
      render_ap ActorSerializer.group(actor)
    end

    # GET /actor — the instance actor that signs outbound fetches
    def instance
      render_ap ActorSerializer.instance
    end

    # The instance actor advertises an outbox, so one has to exist: an
    # advertised collection that 404s is a dangling reference (INTEROP §2.2
    # AC-8). It is legitimately empty — this actor only ever signs fetches, it
    # publishes nothing.
    def instance_outbox
      render_ap({
        "@context" => JsonLd::AS,
        "id" => "#{Urls.instance_actor_url}/outbox",
        "type" => "OrderedCollection",
        "totalItems" => 0,
        "orderedItems" => []
      })
    end
  end
end
