module Federation
  # followers / following / outbox as paged OrderedCollections.
  #
  # Nebula returned every follower in one array and capped its outbox at 100
  # while reporting that cap as the total — both were listed as things not to
  # repeat. Here the collection itself carries only the total and a link to the
  # first page; items live on OrderedCollectionPage, and totalItems is the real
  # count, not the page size.
  class CollectionsController < BaseController
    PAGE_SIZE = 40

    def followers
      collection_for(:followers)
    end

    def following
      collection_for(:following)
    end

    def outbox
      actor = find_actor or return head(:not_found)
      scope = outbox_scope(actor)
      render_paged(
        id: Urls.outbox_url(actor),
        total: scope.count,
        page_items: ->(page) {
          scope.order(start_time: :desc).offset(page * PAGE_SIZE).limit(PAGE_SIZE).map { |event|
            {
              "id" => "#{Urls.event_url(event)}/activity/create",
              "type" => "Create",
              "actor" => Urls.actor_url(actor),
              "published" => event.created_at.utc.iso8601,
              "to" => [JsonLd::PUBLIC],
              "object" => Urls.event_url(event)
            }
          }
        }
      )
    end

    private

    def outbox_scope(actor)
      base = Event.where(visibility: "public", status: "published")
      actor.is_a?(Group) ? base.where(group: actor) : base.where(owner: actor)
    end

    def collection_for(kind)
      actor = find_actor or return head(:not_found)
      direction = kind == :followers ? "inbound" : "outbound"
      scope = FedFollow.accepted.where(local: actor, direction: direction)
      url = kind == :followers ? Urls.followers_url(actor) : Urls.following_url(actor)
      render_paged(
        id: url,
        total: scope.count,
        page_items: ->(page) {
          scope.order(:created_at).offset(page * PAGE_SIZE).limit(PAGE_SIZE)
               .includes(:fed_actor).map { |f| f.fed_actor.uri }
        }
      )
    end

    # `?page=N` returns the page; no param returns the collection head. That is
    # the shape Mastodon and Mobilizon both serve, and it keeps an actor with
    # many followers from ever building one enormous response.
    def render_paged(id:, total:, page_items:)
      if params[:page].blank?
        return render_ap({
          "@context" => JsonLd::AS,
          "id" => id,
          "type" => "OrderedCollection",
          "totalItems" => total,
          "first" => "#{id}?page=0"
        })
      end

      # clamp: an arbitrary ?page=10^9 is a free deep-OFFSET table scan (P2-3);
      # nothing legitimate walks past what totalItems says exists
      max_page = [(total - 1) / PAGE_SIZE, 0].max
      page = params[:page].to_i.clamp(0, max_page)
      items = page_items.call(page)
      doc = {
        "@context" => JsonLd::AS,
        "id" => "#{id}?page=#{page}",
        "type" => "OrderedCollectionPage",
        "partOf" => id,
        "totalItems" => total,
        "orderedItems" => items
      }
      doc["next"] = "#{id}?page=#{page + 1}" if (page + 1) * PAGE_SIZE < total
      doc["prev"] = "#{id}?page=#{page - 1}" if page.positive?
      render_ap doc
    end

    def find_actor
      if params[:user_handle]
        Urls.find_user(params[:user_handle])
      else
        Urls.find_group(params[:group_handle])
      end
    end
  end
end
