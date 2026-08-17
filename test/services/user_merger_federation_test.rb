require "test_helper"

# fed_participations.user_id is a live FK with no ON DELETE, so before this was
# handled every one of these cases raised ActiveRecord::InvalidForeignKey from
# inside the merge — a 500 on an admin action, for any user who had ever joined
# an event on another server.
class UserMergerFederationTest < ActiveSupport::TestCase
  def remote_event(title = "Remote")
    actor = FedActor.create!(uri: "https://peer.test/users/#{SecureRandom.hex(4)}",
                             domain: "peer.test", actor_type: "Person",
                             inbox_url: "https://peer.test/inbox",
                             preferred_username: "peer#{SecureRandom.hex(2)}")
    FedEvent.create!(uri: "https://peer.test/events/#{SecureRandom.hex(4)}",
                     fed_actor_id: actor.id, title: title, status: "CONFIRMED")
  end

  def join(user, fed_event, status: "attending")
    FedParticipation.create!(user: user, fed_event: fed_event, status: status,
                             uri: "https://sola.day/join/#{SecureRandom.hex(4)}")
  end

  test "a remote participation moves to the surviving account" do
    from = create_user
    into = create_user
    event = remote_event
    part = join(from, event)

    UserMerger.call(from: from, into: into)

    assert_equal into.id, part.reload.user_id
    assert_not User.exists?(from.id)
  end

  # unique(user_id, fed_event_id): repointing blindly would violate it, which is
  # why this table needs the same dedup memberships and participants get.
  test "both accounts on the same remote event keeps one row, the survivor's" do
    from = create_user
    into = create_user
    event = remote_event
    from_part = join(from, event, status: "attending")
    into_part = join(into, event, status: "pending")

    UserMerger.call(from: from, into: into)

    assert_not FedParticipation.exists?(from_part.id)
    assert FedParticipation.exists?(into_part.id)
    assert_equal 1, FedParticipation.where(fed_event_id: event.id).count
  end

  test "participations on different remote events all survive" do
    from = create_user
    into = create_user
    a = join(from, remote_event("A"))
    b = join(from, remote_event("B"))

    UserMerger.call(from: from, into: into)

    assert_equal [ into.id, into.id ], [ a.reload.user_id, b.reload.user_id ]
  end

  # The other path that destroys a user. It merges a nameless WeChat shell, and
  # an account can join a remote event before it ever picks a name — onboarding
  # asks for the username last.
  test "destroying a user with a remote participation does not raise" do
    user = create_user
    join(user, remote_event)

    assert_nothing_raised { user.destroy! }
    assert_equal 0, FedParticipation.where(user_id: user.id).count
  end
end
