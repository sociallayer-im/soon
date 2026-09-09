require "test_helper"

class PollAutoCloseJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @owner = create_user
    @voter = create_user
    @group = create_group(owner: @owner, poll_enabled: true)
    create_membership(user: @voter, group: @group)
  end

  test "stamps closed_at and mails author and voters exactly once" do
    poll = create_poll(group: @group, user: @owner, close_at: 1.minute.ago)
    poll.poll_votes.create!(user: @voter, option: poll.poll_options.first)
    poll.poll_votes.create!(user: @owner, option: poll.poll_options.first)
    untouched = create_poll(group: @group, user: @owner, close_at: 1.hour.from_now)
    manual = create_poll(group: @group, user: @owner, close_at: 1.minute.ago, closed_at: 1.minute.ago)

    assert_enqueued_emails 2 do
      PollAutoCloseJob.perform_now
    end
    assert_equal poll.close_at.to_i, poll.reload.closed_at.to_i
    assert_nil untouched.reload.closed_at
    assert_equal manual.closed_at.to_i, manual.reload.closed_at.to_i

    assert_enqueued_emails 0 do
      PollAutoCloseJob.perform_now
    end
  end
end
