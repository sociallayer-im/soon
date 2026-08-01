module Federation
  class ActorsController < BaseController
    # GET /users/:handle
    def user
      actor = User.find_by(name: params[:handle]) or return head(:not_found)
      return redirect_to("#{web_url}/profile/#{actor.name}", allow_other_host: true) unless ap_request?
      render_ap ActorSerializer.user(actor)
    end

    # GET /groups/:handle
    def group
      actor = Group.find_by(name: params[:handle]) or return head(:not_found)
      return redirect_to("#{web_url}/group/#{actor.name}", allow_other_host: true) unless ap_request?
      render_ap ActorSerializer.group(actor)
    end

    # GET /actor — the instance actor that signs outbound fetches
    def instance
      render_ap ActorSerializer.instance
    end
  end
end
