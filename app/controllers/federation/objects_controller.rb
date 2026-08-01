module Federation
  class ObjectsController < BaseController
    # GET /events/:id — the AP view of an event. Anonymous fetches see only
    # what EventPolicy#show? gives an anonymous API caller: public and not
    # draft/pending/archived. cancelled serves with status CANCELLED so
    # receivers learn about the cancellation on refetch.
    SERVABLE_STATUSES = %w[published closed cancelled].freeze

    def event
      event = Event.find_by(id: params[:id]) or return head(:not_found)
      unless event.visibility == "public" && SERVABLE_STATUSES.include?(event.status)
        return head :not_found
      end
      return redirect_to(Urls.event_html_url(event), allow_other_host: true) unless ap_request?
      render_ap EventSerializer.new(event).as_ap
    end
  end
end
