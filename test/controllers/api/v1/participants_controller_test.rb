require "test_helper"

class Api::V1::ParticipantsControllerTest < ActionDispatch::IntegrationTest
  test "create defaults to attending when no approval/form is required" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "attending", json_response["status"]
  end

  test "create is pending when event.require_approval is true and caller isn't a group admin" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "create is attending (bypasses approval) when caller is a group admin" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(admin)
    assert_response :created
    assert_equal "attending", json_response["status"]
  end

  test "create is pending when the event has a form attached" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "create rejects join when a required form field is missing" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)
    field = create_form_field(form: form, required: true, for_admin: false)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
    assert_match "missing required form fields", json_response["error"]
    assert_not event.participants.exists?(user: attendee)
  end

  test "create succeeds and stores answers when required fields are present" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)
    field = create_form_field(form: form, required: true, for_admin: false)

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "yes" }] },
      headers: auth_headers(attendee)
    assert_response :created

    submission = FormSubmission.find_by(form: form, user: attendee)
    assert submission
    assert_equal "yes", submission.form_answers.first.value
  end

  test "create rejects a duplicate participant for the same user/event" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: attendee)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
  end

  test "a rejected applicant may apply again" do
    owner = create_user
    applicant = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant)
    participant = Participant.find(json_response["id"])
    post "/api/v1/events/#{event.id}/participants/#{participant.id}/reject", headers: auth_headers(owner)
    assert_response :success
    assert_equal "declined", participant.reload.status

    # "declined" is a decision on one application, not a ban: the transition
    # table has always allowed declined → pending, and this is the path that
    # uses it.
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant)
    assert_response :created
    assert_equal "pending", json_response["status"]
    assert_equal participant.id, json_response["id"], "the row is reused — (user, event) is unique"
    assert_equal 1, Participant.where(event: event, user: applicant).count
  end

  test "re-applying clears the rejection from the form submission too" do
    owner = create_user
    applicant = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form(created_by_id: owner.id)
    field = create_form_field(form: form)
    event.update!(form_id: form.id)

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "first try" }] },
      headers: auth_headers(applicant), as: :json
    participant = Participant.find(json_response["id"])
    post "/api/v1/events/#{event.id}/participants/#{participant.id}/reject", headers: auth_headers(owner)
    assert_equal "rejected", FormSubmission.find_by(form_id: form.id, user_id: applicant.id).status

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "second try" }] },
      headers: auth_headers(applicant), as: :json
    assert_response :created

    submission = FormSubmission.find_by(form_id: form.id, user_id: applicant.id)
    # The two views of one application must not disagree: the organizer's
    # submission list would otherwise still show "rejected" next to a
    # participant who is back under review.
    assert_equal "pending", submission.status
    assert_equal ["second try"], submission.form_answers.map(&:value)
  end

  test "re-applying with no answers still clears the rejection, without inventing a response" do
    owner = create_user
    applicant = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    # No REQUIRED fields, so an application may legitimately carry no answers.
    form = create_form(created_by_id: owner.id)
    create_form_field(form: form, required: false)
    event.update!(form_id: form.id)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant), as: :json
    participant = Participant.find(json_response["id"])
    assert_nil FormSubmission.find_by(form_id: form.id, user_id: applicant.id),
      "no answers means no response — an empty row is not a submission"

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/reject", headers: auth_headers(owner)
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant), as: :json
    assert_response :created
    assert_equal "pending", participant.reload.status
    assert_nil FormSubmission.find_by(form_id: form.id, user_id: applicant.id)
  end

  test "an applicant can withdraw while under review and then apply again" do
    owner = create_user
    applicant = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant)
    participant = Participant.find(json_response["id"])
    assert_equal "pending", participant.status

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(applicant)
    assert_response :no_content
    assert_equal "cancelled", participant.reload.status
    # No seat was held while pending, so withdrawing must not give one back.
    assert_equal 0, event.reload.participant_count.to_i

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(applicant)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "index lists participants for an event" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: attendee)

    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(owner)
    assert_response :success
    assert_equal 1, json_response["data"].size
  end

  test "index serves an anonymous visitor for a public event" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "normal")
    create_participant(event: event, user: attendee)

    # The detail page can now ask for the event without the embedded attendee
    # array, so a signed-out visitor has to be able to fetch the list here —
    # they could always read it off GET /events/:id.
    get "/api/v1/events/#{event.id}/participants"
    assert_response :success
    assert_equal 1, json_response["data"].size
  end

  test "index shows an unlisted event's attendees to anyone, matching EventPolicy#show?" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "unlisted")
    create_participant(event: event, user: owner)

    # Tied to EventPolicy#show? (see participants_controller.rb#index) — as of
    # 2026-08-24 that means "visible via direct link to anyone," same as the
    # event itself, not "group members only."
    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(outsider)
    assert_response :success

    get "/api/v1/events/#{event.id}/participants"
    assert_response :success
  end

  test "index hides a draft event's attendees from everyone but its managers" do
    owner = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "draft")
    create_participant(event: event, user: owner)

    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(owner)
    assert_response :success
  end

  test "index excludes withdrawn participants" do
    owner = create_user
    attendee = create_user
    withdrawn = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, status: "published", visibility: "normal")
    create_participant(event: event, user: attendee)
    create_participant(event: event, user: withdrawn, status: "cancelled")

    get "/api/v1/events/#{event.id}/participants"
    assert_response :success
    assert_equal [attendee.id], json_response["data"].map { |p| p.dig("user", "id") }
  end

  test "update is self-only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee)

    patch "/api/v1/events/#{event.id}/participants/#{participant.id}",
      params: { participant: { status: "maybe" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/events/#{event.id}/participants/#{participant.id}",
      params: { participant: { status: "maybe" } }, headers: auth_headers(attendee)
    assert_response :success
    assert_equal "maybe", participant.reload.status
  end

  test "destroy is self-only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee)

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content
  end

  test "destroy soft-deletes: the row survives as cancelled and leaves the attendee list" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee, status: "attending")
    event.increment!(:participant_count)

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content

    assert Participant.exists?(participant.id), "history must survive — no hard delete"
    assert_equal "cancelled", participant.reload.status
    assert_equal 0, event.reload.participant_count

    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(owner)
    assert_empty json_response["data"], "a withdrawn participant is not in the attendee list"

    get "/api/v1/events/#{event.id}", headers: auth_headers(owner)
    assert_empty json_response["participants"], "nor in the event detail payload"

    # Idempotent — a second withdrawal must not decrement the count again.
    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content
    assert_equal 0, event.reload.participant_count
  end

  test "withdrawing from a ticketed event releases the pending order and its hold" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :success
    item = TicketItem.find(json_response["ticket_item"]["id"])
    participant = Participant.find(json_response["participant"]["id"])
    assert_equal 4, ticket.reload.quantity

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_response :no_content

    assert_equal "cancelled", item.reload.status
    assert_equal 5, ticket.reload.quantity, "the hold must be handed back"
    assert_equal 0, event.reload.participant_count
  end

  test "withdrawing keeps a PAID order refundable by the organizer" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    item = TicketItem.find(json_response["ticket_item"]["id"])
    participant = Participant.find(json_response["participant"]["id"])
    item.confirm_payment!(txhash: "pi_paid")

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_response :no_content

    # The money is still with the organizer, so the order stays succeeded and
    # refundable — withdrawing is not a refund.
    assert_equal "succeeded", item.reload.status
    assert_equal participant.id, item.participant_id, "the refund path still needs the participant"
    assert_equal 5, ticket.reload.quantity, "the seat is freed even though the order stands"
  end

  test "withdrawing from a free ticketed event retires the order" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    item = TicketItem.find(json_response["ticket_item"]["id"])
    participant = Participant.find(json_response["participant"]["id"])
    assert_equal "succeeded", item.status

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_response :no_content
    assert_equal "cancelled", item.reload.status, "nothing to refund on a free order"
    assert_equal 5, ticket.reload.quantity
  end

  test "re-joining after withdrawing reuses the row, re-stamps registered_at, and retakes a seat" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    # max_participant: 1 proves a withdrawn participant occupies no capacity.
    event = create_event(group: group, owner: owner, max_participant: 1)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    participant = Participant.find(json_response["id"])
    first_registered_at = participant.registered_at
    assert_equal 1, event.reload.participant_count

    # Event is full for anyone else.
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(create_user)
    assert_response :unprocessable_entity

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content
    assert_equal 0, event.reload.participant_count, "a withdrawn participant occupies no seat"

    # The freed seat is genuinely available to someone else...
    other = create_user
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(other)
    assert_response :created
    other_participant = Participant.find(json_response["id"])
    delete "/api/v1/events/#{event.id}/participants/#{other_participant.id}", headers: auth_headers(other)

    # ...and re-joining reuses the SAME row rather than inserting a second.
    travel 1.minute do
      assert_no_difference -> { Participant.where(event_id: event.id, user_id: attendee.id).count } do
        post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
      end
      assert_response :created
      assert_equal participant.id, json_response["id"]
    end
    participant.reload
    assert_equal "attending", participant.status
    assert participant.registered_at > first_registered_at, "signing up again re-stamps registered_at"
    assert_equal 1, event.reload.participant_count
  end

  test "a withdrawn participant cannot be checked in" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee, status: "attending")
    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)

    post "/api/v1/events/#{event.id}/participants/check_in",
      params: { user_id: attendee.id }, headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_nil participant.reload.checked_in_at
  end

  test "buying a ticket for an approval-required event does not skip approval" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)
    ticket = create_ticket(event: event, quantity: 5)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    participant = Participant.find(json_response["participant"]["id"])
    assert_equal "pending", participant.status, "paying must not bypass the organizer's approval"
    assert_equal 0, event.reload.participant_count, "an unapproved buyer holds no seat"

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal "attending", participant.reload.status
    assert_equal 1, event.reload.participant_count
  end

  test "a need_approval ticket puts the buyer in pending even without event-level approval" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5, need_approval: true)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    assert_equal "pending", Participant.find(json_response["participant"]["id"]).status
  end

  test "cancelling one of several orders does not withdraw a participant who still has a paid one" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    paid_ticket = create_ticket(event: event, quantity: 5)
    extra_ticket = create_ticket(event: event, quantity: 5)
    paid_pm = create_payment_method(item: paid_ticket, chain: "stripe", price: 1000)
    extra_pm = create_payment_method(item: extra_ticket, chain: "stripe", price: 1000)

    post "/api/v1/events/#{event.id}/tickets/#{paid_ticket.id}/rsvp",
      params: { payment_method_id: paid_pm.id }, headers: auth_headers(buyer)
    paid_item = TicketItem.find(json_response["ticket_item"]["id"])
    participant = Participant.find(json_response["participant"]["id"])
    paid_item.confirm_payment!(txhash: "pi_kept")

    # A second, unpaid order for the same event.
    post "/api/v1/events/#{event.id}/tickets/#{extra_ticket.id}/rsvp",
      params: { payment_method_id: extra_pm.id }, headers: auth_headers(buyer)
    assert_response :success
    extra_item = TicketItem.find(json_response["ticket_item"]["id"])

    extra_item.cancel

    assert_equal "attending", participant.reload.status,
      "abandoning one checkout must not drop an attendance already paid for"
    assert_equal "succeeded", participant.payment_status,
      "payment_status summarises the orders — a paid one is still there"
  end

  # ---- participant_count follows the SEAT, never the order ----
  #
  # The counter used to move in TicketItem#release_resources!, which fires once
  # per order. These three are the shapes that broke: more orders than seats,
  # an order that never held a seat, and a seat with no order behind it.

  test "abandoning a second order does not take away a seat the buyer still holds" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    free = create_ticket(event: event, quantity: 5)
    paid = create_ticket(event: event, quantity: 5)
    pm = create_payment_method(item: paid, chain: "stripe", price: 1000)

    post "/api/v1/events/#{event.id}/tickets/#{free.id}/rsvp", headers: auth_headers(buyer)
    assert_equal 1, event.reload.participant_count

    post "/api/v1/events/#{event.id}/tickets/#{paid.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    second = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal 1, event.reload.participant_count, "a second order is not a second seat"

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { ticket_item_id: second.id }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal "attending", Participant.find_by(event: event, user: buyer).status
    assert_equal 1, event.reload.participant_count,
      "they are still attending on the other order, so the seat is still taken"
  end

  test "cancelling an order that never held a seat leaves the count alone" do
    owner = create_user
    attendee = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    # Somebody else is genuinely seated, so a stray decrement has something to
    # steal — with an empty event the `> 0` floor hides the bug.
    create_participant(event: event, user: attendee, status: "attending")
    event.update!(participant_count: 1)

    gated = create_ticket(event: event, quantity: 5, need_approval: true)
    pm = create_payment_method(item: gated, chain: "stripe", price: 1000)
    post "/api/v1/events/#{event.id}/tickets/#{gated.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal "pending", Participant.find_by(event: event, user: buyer).status
    assert_equal 1, event.reload.participant_count, "an unapproved buyer holds no seat"

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { ticket_item_id: item.id }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal 1, event.reload.participant_count,
      "they never had a seat, so cancelling must not hand one back — least of all somebody else's"
  end

  test "the count survives a full withdraw and re-register cycle" do
    owner = create_user
    buyer = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    ticket = create_ticket(event: event, quantity: 5)

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    participant = Participant.find_by(event: event, user: buyer)
    assert_equal 1, event.reload.participant_count

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_equal 0, event.reload.participant_count

    post "/api/v1/events/#{event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    assert_equal 1, event.reload.participant_count
    # 5 → 4 on the first RSVP, back to 5 on withdrawal, 4 again now: the
    # abandoned attempt left no unit stranded.
    assert_equal 4, ticket.reload.quantity
  end

  test "approve and reject advance the application form submission too" do
    owner = create_user
    applicant = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    field = create_form_field(form: form, required: true, for_admin: false)
    event.update!(form_id: form.id)

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "why me" }] }, headers: auth_headers(applicant)
    assert_response :created
    participant = Participant.find(json_response["id"])
    submission = FormSubmission.find_by(form_id: form.id, user_id: applicant.id)
    assert_equal "pending", submission.status

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal "approved", submission.reload.status,
      "a decided applicant must not still read as pending in the submissions list"
  end

  test "approve moves a pending participant to attending, event owner only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "approve works for a group admin too, not just the event owner" do
    owner = create_user
    admin = create_user
    attendee = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "manager")
    event = create_event(group: group, owner: owner, require_approval: true)
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(admin)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "approve works for an event co-host too" do
    owner = create_user
    cohost = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)
    event.event_roles.create!(item_id: cohost.id, item_type: "User", role: "co_host")
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(cohost)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "check_in works for an event co-host too" do
    owner = create_user
    cohost = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    event.event_roles.create!(item_id: cohost.id, item_type: "User", role: "co_host")
    create_participant(event: event, user: attendee, status: "attending")

    post "/api/v1/events/#{event.id}/participants/check_in", params: { user_id: attendee.id },
      headers: auth_headers(cohost)
    assert_response :success
  end

  test "approve 422s on a non-pending participant" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee, status: "attending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "attending", participant.reload.status
  end

  test "approve 404s for an unknown participant" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants/does-not-exist/approve", headers: auth_headers(owner)
    assert_response :not_found
  end

  # ---------------------------------------------------------------- capacity

  test "create is rejected once max_participant is reached" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, max_participant: 1)
    create_participant(event: event, user: create_user, status: "attending")
    event.increment!(:participant_count)

    attendee = create_user
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
    assert_not event.participants.exists?(user: attendee)
  end

  test "create is rejected once the venue's capacity is reached" do
    owner = create_user
    group = create_group(owner: owner)
    venue = create_venue(group: group, owner: owner, capacity: 1)
    event = create_event(group: group, owner: owner, venue: venue)
    create_participant(event: event, user: create_user, status: "attending")
    event.increment!(:participant_count)

    attendee = create_user
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
  end

  test "a pending join (awaiting approval) doesn't count against capacity" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, max_participant: 1, require_approval: true)
    create_participant(event: event, user: create_user, status: "attending")
    event.increment!(:participant_count)

    attendee = create_user
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "create increments participant_count only when attending" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(create_user)
    assert_equal 1, event.reload.participant_count
  end

  test "destroy decrements participant_count for an attending participant" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee, status: "attending")
    event.increment!(:participant_count)

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content
    assert_equal 0, event.reload.participant_count
  end

  test "self-cancel via update decrements participant_count and frees a seat" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, max_participant: 1)
    participant = create_participant(event: event, user: attendee, status: "attending")
    event.increment!(:participant_count)

    patch "/api/v1/events/#{event.id}/participants/#{participant.id}",
      params: { participant: { status: "cancelled" } }, headers: auth_headers(attendee)
    assert_response :success
    assert_equal 0, event.reload.participant_count

    newcomer = create_user
    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(newcomer)
    assert_response :created
  end

  test "approve increments participant_count" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal 1, event.reload.participant_count
  end
end
