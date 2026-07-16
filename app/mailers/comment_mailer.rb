class CommentMailer < ApplicationMailer
  # Notifies the owner of the commented-on item (e.g. an event) that someone left
  # feedback. Only used for feedback-type comments.
  def feedback(comment_id:)
    @comment = Comment.find(comment_id)
    @item    = @comment.item
    @author  = @comment.user
    recipient = @item.try(:owner)&.email
    return if recipient.blank?

    mail(to: recipient, subject: "New feedback on #{item_label}")
  end

  private

  def item_label
    @item.try(:title).presence || "your #{@item.class.name.underscore.humanize.downcase}"
  end
end
