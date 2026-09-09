class PollMailer < ApplicationMailer
  # Sent once by PollAutoCloseJob when a poll reaches its deadline, to the
  # author and everyone who voted. A manual close sends nothing.
  def closed(poll_id:, recipient:)
    @poll  = Poll.find(poll_id)
    @group = @poll.group
    @poll_url = "#{WEB_URL}/event/#{@group.name}/poll/#{@poll.id}"
    mail(to: recipient, subject: "Poll closed: #{@poll.title}")
  end
end
