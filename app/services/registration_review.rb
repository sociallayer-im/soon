# A pending application holds neither a ticket unit nor an event seat.
# Approval is the only point at which both independent limits are checked.
class RegistrationReview
  class Error < StandardError; end

  def self.approve!(participant, actor:)
    event = participant.event
    event.with_lock do
      participant.with_lock do
        raise Error, "participant is not pending" unless participant.status == "pending"
        raise Error, "活动已结束或停止报名" if %w[closed cancelled archived draft].include?(event.status) || (event.end_time && event.end_time < Time.current)
        raise Error, "event is full" if capacity_full?(event)
        items = participant.ticket_items.where(status: %w[pending succeeded]).order(:id).lock.to_a
        items.each do |item|
          raise Error, "该票种已停止报名" if item.ticket.status != "normal" || (item.ticket.end_time && item.ticket.end_time <= Time.current)
          unless item.inventory_reserved?
            raise Error, "该票种名额不足" unless item.ticket.reserve!
            item.update!(inventory_reserved: true)
          end
        end
        payable = items.select { |item| item.status == "pending" && item.amount.to_i.positive? }
        deadline = [24.hours.from_now, event.end_time, *payable.map { |item| item.ticket.end_time }].compact.min
        raise Error, "报名已截止" if payable.any? && deadline <= Time.current
        participant.transition!(payable.any? ? :awaiting_payment : :attending,
          reviewed_by: actor, reviewed_at: Time.current, review_reason: nil,
          payment_due_at: payable.any? ? deadline : nil)
        payable.each { |item| item.update!(reserved_until: deadline) }
        items.select { |item| item.status == "pending" && item.amount.to_i.zero? }.each(&:confirm_payment!)
        participant.refresh_payment_status!
        sync_form!(participant, "approved")
      end
    end
  end

  def self.reject!(participant, actor:, reason:)
    reason = reason.to_s.strip
    raise Error, "请填写拒绝原因" if reason.blank? || reason.length > 500
    participant.event.with_lock do
      participant.with_lock do
        raise Error, "participant is not pending" unless participant.status == "pending"
        # Decide first; cancelling orders must not overwrite the decision.
        participant.transition!(:declined, reviewed_by: actor, reviewed_at: Time.current, review_reason: reason, payment_due_at: nil)
        participant.ticket_items.where(status: "pending").order(:id).each { |item| item.cancel(actor: actor) }
        participant.reload.refresh_payment_status!
        sync_form!(participant, "rejected")
      end
    end
  end

  def self.capacity_full?(event)
    holds = event.participants.where(status: "awaiting_payment").count
    used = event.participant_count.to_i + holds
    (event.max_participant && used >= event.max_participant) || (event.venue&.capacity.to_i > 0 && used >= event.venue.capacity)
  end

  def self.sync_form!(participant, status)
    return unless participant.event.form_id
    FormSubmission.where(form_id: participant.event.form_id, user_id: participant.user_id).update_all(status: status, updated_at: Time.current)
  end
end
