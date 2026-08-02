module Federation
  # A comment on an event as an AS2 Note. Top-level comments reply to the
  # event itself — that inReplyTo is what makes a Mastodon reply to a boosted
  # event land back on the event page, and vice versa (Mobilizon
  # converter/comment.ex:98-127 does the same).
  class CommentSerializer
    def initialize(comment, event)
      @comment = comment
      @event = event
    end

    # The actor a note is attributed to must be the one whose key signs it;
    # a commenter without a handle has no actor, so the group owns the note.
    def author_actor
      @comment.user&.name.present? ? @comment.user : @event.group
    end

    def as_ap(context: true)
      doc = {
        "type" => "Note",
        "id" => Urls.activity_url("comments/#{@comment.id}"),
        "attributedTo" => Urls.actor_url(author_actor),
        "actor" => Urls.actor_url(author_actor),
        "inReplyTo" => in_reply_to,
        "content" => sanitized_content,
        "mediaType" => "text/html",
        "published" => @comment.created_at.utc.iso8601,
        "to" => [JsonLd::PUBLIC],
        "cc" => [Urls.followers_url(@event.group)]
      }
      doc["@context"] = JsonLd.context if context
      # FEP-8b32: proofs bind the @context, so only the standalone (full
      # context) form is signed. Embedders must carry the object whole.
      context ? IntegrityProof.sign(doc, author_actor, created: @comment.updated_at) : doc
    end

    def in_reply_to
      if @comment.reply_parent_id
        Urls.activity_url("comments/#{@comment.reply_parent_id}")
      else
        Urls.event_url(@event)
      end
    end

    def sanitized_content
      ActionController::Base.helpers.sanitize(@comment.content.to_s)
    end
  end
end
