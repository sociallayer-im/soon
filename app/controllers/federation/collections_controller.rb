module Federation
  # followers / following / outbox as OrderedCollections. Phase 1: real
  # totalItems (the nebula limited-count bug is a named regression), paged
  # items land in Phase 2 with real follow data.
  class CollectionsController < BaseController
    PAGE_SIZE = 20

    def followers
      collection_for(:followers)
    end

    def following
      collection_for(:following)
    end

    def outbox
      actor = find_actor or return head(:not_found)
      total =
        if actor.is_a?(Group)
          actor.events.where(visibility: "public", status: "published").count
        else
          Event.where(owner: actor, visibility: "public", status: "published").count
        end
      render_ap ordered_collection(Urls.outbox_url(actor), total)
    end

    private

    def collection_for(kind)
      actor = find_actor or return head(:not_found)
      direction = kind == :followers ? "inbound" : "outbound"
      total = FedFollow.accepted.where(local: actor, direction: direction).count
      url = kind == :followers ? Urls.followers_url(actor) : Urls.following_url(actor)
      render_ap ordered_collection(url, total)
    end

    def ordered_collection(id, total)
      {
        "@context" => JsonLd::AS,
        "id" => id,
        "type" => "OrderedCollection",
        "totalItems" => total,
        "orderedItems" => []
      }
    end

    def find_actor
      if params[:user_handle]
        User.find_by(name: params[:user_handle])
      else
        Group.find_by(name: params[:group_handle])
      end
    end
  end
end
