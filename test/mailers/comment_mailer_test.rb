require "test_helper"

class CommentMailerTest < ActionMailer::TestCase
  test "feedback emails the item owner with the comment body" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, title: "My Event")
    author = create_user(name: "feedback-author")
    comment = create_comment(user: author, item: event, comment_type: "feedback")

    mail = CommentMailer.feedback(comment_id: comment.id)

    assert_equal [owner.email], mail.to
    assert_equal "New feedback on My Event", mail.subject
    assert_match "feedback-author", mail.html_part.body.to_s
    assert_match comment.content, mail.html_part.body.to_s
  end

  test "feedback does not send when the item owner cannot be resolved" do
    author = create_user
    # BadgeClass has a creator, not an owner, so no recipient can be derived.
    badge_class = create_badge_class(creator: author)
    comment = create_comment(user: author, item: badge_class, comment_type: "feedback")

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      CommentMailer.feedback(comment_id: comment.id).deliver_now
    end
  end
end
