require "test_helper"

class Api::V1::TicketsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @group = create_group(owner: @owner, nickname: "group-#{unique_suffix}")
    @event = create_event(group: @group, owner: @owner)
  end

  # ---------------------------------------------------------------- rsvp

  test "rsvp on a free ticket succeeds immediately with amount 0" do
    ticket = create_ticket(event: @event)
    buyer = create_user(email: "buyer@test.com")

    assert_enqueued_emails 1 do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    end
    assert_response :success

    assert_equal "succeeded", json_response["ticket_item"]["status"]
    assert_equal 0, json_response["ticket_item"]["amount"]
    assert_equal "attending", json_response["participant"]["status"]
    assert_equal "succeeded", json_response["participant"]["payment_status"]

    participant = Participant.find(json_response["participant"]["id"])
    job = enqueued_jobs.find { |j| j[:args][1] == "ticket_purchased" }
    assert job, "expected EventMailer#ticket_purchased to be enqueued"
    assert_equal participant.id, job[:args][3]["args"][0]["participant_id"]
  end

  test "rsvp on a group-gated ticket rejects a non-member and admits a member of ANY listed group" do
    other_group = create_group(owner: @owner, nickname: "members-#{unique_suffix}")
    ticket = create_ticket(event: @event, check_group_ids: [ other_group.id, @group.id ])
    outsider = create_user
    member = create_user
    create_membership(user: member, group: other_group)

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(member)
    assert_response :success
    assert_equal "attending", json_response["participant"]["status"]
    assert_equal 0, json_response["ticket_item"]["amount"]
  end

  test "rsvp rolls back atomically when a later step fails after the ticket_item saved" do
    ticket = create_ticket(event: @event, quantity: 1)
    buyer = create_user
    form = create_form
    field = create_form_field(form: form, required: true, for_admin: false)
    @event.update!(form_id: form.id)

    # Force a failure AFTER ticket_item.save! but inside the rsvp transaction
    # (a bad form answer). The whole order — participant, ticket_item, count bump,
    # coupon usage — must roll back, and the reservation must be handed back so no
    # half-committed state or leaked slot survives.
    FormAnswer.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid.new(FormAnswer.new) }) do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
        params: { answers: [{ field_id: field.id, value: "reason" }] }, headers: auth_headers(buyer)
    end

    assert_response :unprocessable_entity
    assert_equal 1, ticket.reload.quantity, "quantity must be released — the transaction rolled the reservation back"
    assert_not TicketItem.exists?(ticket: ticket, user: buyer), "no ticket_item should survive the rolled-back order"
    assert_equal 0, @event.reload.participant_count, "the participant_count bump must roll back too"
  end

  test "rsvp releases ticket quantity when the failure happens before the ticket_item ever persists" do
    ticket = create_ticket(event: @event, quantity: 1)
    buyer = create_user

    # Force participant.save! itself to fail, before ticket_item.save! ever runs.
    # minitest-mock has no any_instance stub, so patch the instance method directly.
    original = Participant.instance_method(:save!)
    Participant.define_method(:save!) { raise ActiveRecord::RecordInvalid.new(self) }
    begin
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    ensure
      Participant.define_method(:save!, original)
    end

    assert_response :unprocessable_entity
    assert_equal 1, ticket.reload.quantity, "quantity must be released — nothing was actually persisted"
  end

  test "rsvp on a paid stripe ticket above the waiver threshold stays pending" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :success

    assert_equal "pending", json_response["ticket_item"]["status"]
    assert_equal 1000, json_response["ticket_item"]["amount"]
    # The order snapshots what it is priced in. Nothing downstream — refunds,
    # the webhook's amount/currency check, the price the buyer is shown — may
    # have to re-derive this from the rail's current default.
    assert_equal "usd", json_response["ticket_item"]["currency"]
    assert_equal "stripe", TicketItem.find(json_response["ticket_item"]["id"]).payment_provider
  end

  test "a crypto order carries no currency — its amount is denominated in the token" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "ethereum", kind: "crypto",
      token_name: "USDT", price: 10_000, receiver_address: "0xabc")
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "ethereum" }, headers: auth_headers(buyer)
    assert_response :success

    item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_nil item.currency
    assert_equal "evm", item.payment_provider
  end

  test "rsvp rejects a legacy sub-minimum stripe amount instead of waiving it to free" do
    ticket = create_ticket(event: @event, quantity: 5)
    # Pre-validation legacy row: creation now rejects sub-minimum stripe prices,
    # but rows created before the floor existed can still be in the DB.
    pm = PaymentMethod.new(item: ticket, chain: "stripe", kind: "fiat", price: 350)
    pm.save!(validate: false)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "below the minimum", json_response["error"]
    assert_equal 5, ticket.reload.quantity, "failed rsvp must release the reserved unit"
    assert_equal 0, TicketItem.where(ticket_id: ticket.id).count
  end

  test "a stripe payment method under the $4 floor is rejected at ticket creation" do
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Cheap", ticket_type: "event",
                          payment_methods_attributes: [{ chain: "stripe", kind: "fiat", price: 350 }] } },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "crypto payment", json_response["error"]

    # A card method with no key at all is unsellable — reject at creation
    # rather than letting a buyer hit "stripe is not configured" at checkout.
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Keyless", ticket_type: "event",
                          payment_methods_attributes: [{ chain: "stripe", kind: "fiat", price: 2500 }] } },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
    assert_match "required for card payments", json_response["error"]

    # stripe_setting_id must survive the permit list (silently-dropped params
    # have caused real data loss here before).
    setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Card", ticket_type: "event",
                          payment_methods_attributes: [{ chain: "stripe", kind: "fiat", price: 2500, stripe_setting_id: setting.id }] } },
      headers: auth_headers(@owner)
    assert_response :created
    assert_equal setting.id, Ticket.find(json_response["id"]).payment_methods.sole.stripe_setting_id

    # A key that is NOT the event owner's is rejected — an editor must not be
    # able to point ticket revenue at their own Stripe account.
    interloper = create_user
    create_membership(user: interloper, group: @group, role: "manager")
    foreign = StripeSetting.create!(user: interloper, name: "Mine", secret_key: "sk_live_x")
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Hijack", ticket_type: "event",
                          payment_methods_attributes: [{ chain: "stripe", kind: "fiat", price: 2500, stripe_setting_id: foreign.id }] } },
      headers: auth_headers(interloper)
    assert_response :unprocessable_entity
    assert_match "belong to the event owner", json_response["error"]

    # The same price is fine on a crypto method — the floor is card-only.
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "CheapCrypto", ticket_type: "event",
                          payment_methods_attributes: [{ chain: "base", kind: "crypto", price: 350 }] } },
      headers: auth_headers(@owner)
    assert_response :created
  end

  test "rsvp refuses a second unpaid order for the same ticket but allows another type" do
    ticket = create_ticket(event: @event, quantity: 5)
    other_ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    other_pm = create_payment_method(item: other_ticket, chain: "stripe", price: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal 4, ticket.reload.quantity

    # Double-click / retry during the confirmation window must not hold a
    # second unit of inventory for the same seat.
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "already have an unpaid order", json_response["error"]
    assert_equal 4, ticket.reload.quantity, "no extra hold"
    assert_equal 1, TicketItem.where(ticket_id: ticket.id, user_id: buyer.id).count

    # A different ticket type of the same event is still purchasable.
    post "/api/v1/events/#{@event.id}/tickets/#{other_ticket.id}/rsvp",
      params: { payment_method_id: other_pm.id }, headers: auth_headers(buyer)
    assert_response :success
  end

  test "a coupon discounting a stripe price into (0, min) is rejected, not waived to free" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, code: "TOO_DEEP", discount_type: "amount", discount: 700)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "TOO_DEEP" }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "not applicable to this payment method", json_response["error"]
    assert_equal 0, coupon.reload.order_usage_count
    assert_equal 5, ticket.reload.quantity
  end

  test "a coupon discounting a stripe price to exactly 0 is a valid free path" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    create_coupon(event: @event, code: "FULL_COMP", discount_type: "amount", discount: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "FULL_COMP" }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal "succeeded", json_response["ticket_item"]["status"]
    assert_equal 0, json_response["ticket_item"]["amount"]
  end

  test "a removed (soft-deleted) coupon no longer redeems anywhere" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    create_coupon(event: @event, code: "GONE", discount_type: "amount", discount: 100, removed: true)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "GONE" }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "not available", json_response["error"]

    get "/api/v1/tickets/check_coupon", params: { event_id: @event.id, code: "GONE" }
    assert_nil json_response["coupon"]

    get "/api/v1/tickets/coupon_price", params: { code: "GONE", amount: 1000 }
    assert_response :unprocessable_entity
  end

  test "a coupon scoped by applicable_ticket_ids only works on its tickets" do
    tier_a = create_ticket(event: @event)
    tier_b = create_ticket(event: @event)
    pm_a = create_payment_method(item: tier_a, chain: "stripe", price: 1000)
    pm_b = create_payment_method(item: tier_b, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, code: "TIER_A_ONLY", discount_type: "amount",
      discount: 100, applicable_ticket_ids: [tier_a.id])

    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{tier_b.id}/rsvp",
      params: { payment_method_id: pm_b.id, coupon: "TIER_A_ONLY" }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "not applicable to this ticket", json_response["error"]
    assert_equal 0, coupon.reload.order_usage_count

    # coupon_price gives the same verdict (the quote must match checkout)
    get "/api/v1/tickets/coupon_price", params: { code: "TIER_A_ONLY", amount: 1000, payment_method_id: pm_b.id }
    assert_response :unprocessable_entity

    post "/api/v1/events/#{@event.id}/tickets/#{tier_a.id}/rsvp",
      params: { payment_method_id: pm_a.id, coupon: "TIER_A_ONLY" }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal 900, json_response["ticket_item"]["amount"]
    assert_equal 1, coupon.reload.order_usage_count
  end

  test "set_coupon _destroy soft-deletes: row kept with removed=true, hidden from the coupons list" do
    coupon = create_coupon(event: @event, code: "BYE", discount_type: "amount", discount: 100)

    post "/api/v1/tickets/set_coupon",
      params: { event_id: @event.id, coupons: [{ id: coupon.id, _destroy: true }] },
      headers: auth_headers(@owner)
    assert_response :success

    assert coupon.reload.removed, "the row must survive as a soft delete"

    get "/api/v1/tickets/coupons", params: { event_id: @event.id }, headers: auth_headers(@owner)
    assert_response :success
    assert_not_includes json_response.map { |c| c["id"] }, coupon.id
  end

  test "rsvp coupon ratio discount: discount is basis points of 10000, final = amount * discount / 10000" do
    ticket = create_ticket(event: @event)
    # Price kept well above the $4 stripe-waiver threshold so the waiver doesn't also kick in.
    pm = create_payment_method(item: ticket, chain: "stripe", price: 10_000)
    coupon = create_coupon(event: @event, code: "RATIO20", discount_type: "ratio", discount: 2000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "RATIO20" }, headers: auth_headers(buyer)
    assert_response :success

    # 10000 * 2000 / 10000 = 2000 — NOT "20% off" (8000 remaining), the discount field IS the
    # resulting fraction to charge, not the fraction removed.
    assert_equal 2000, json_response["ticket_item"]["amount"]
    assert_equal 8000, json_response["ticket_item"]["discount_value"]
    assert_equal 1, coupon.reload.order_usage_count
  end

  test "rsvp coupon amount discount used as-is on stripe" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    create_coupon(event: @event, code: "AMT10", discount_type: "amount", discount: 300)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "AMT10" }, headers: auth_headers(buyer)
    assert_response :success

    assert_equal 700, json_response["ticket_item"]["amount"]
    assert_equal 300, json_response["ticket_item"]["discount_value"]
  end

  test "rsvp coupon amount discount scaled x10000 on a non-stripe chain" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1_000_000, chains: ["base"])
    create_coupon(event: @event, code: "AMTCRYPTO", discount_type: "amount", discount: 30)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base", coupon: "AMTCRYPTO" }, headers: auth_headers(buyer)
    assert_response :success

    # discount 30 * 10_000 = 300_000
    assert_equal 700_000, json_response["ticket_item"]["amount"]
    assert_equal 300_000, json_response["ticket_item"]["discount_value"]
  end

  test "rsvp coupon amount discount clamps to the item price, never goes negative" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 500)
    create_coupon(event: @event, code: "HUGE", discount_type: "amount", discount: 10_000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "HUGE" }, headers: auth_headers(buyer)
    assert_response :success

    # Clamped to exactly 0 — the valid free path, not the (0, min) rejection.
    assert_equal 0, json_response["ticket_item"]["amount"]
    assert_equal 500, json_response["ticket_item"]["discount_value"]
  end

  # Note: this differs from Coupon#get_discounted_price's own behavior (silent no-discount
  # pass-through, see the model test) — the rsvp purchase flow adds its own stricter pre-check
  # and hard-rejects expired/exhausted coupons instead of silently charging full price.
  test "rsvp with an expired coupon is rejected outright (no ticket_item created)" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    create_coupon(event: @event, code: "EXPIRED", discount_type: "ratio", discount: 5000, expires_at: 1.day.ago)
    buyer = create_user

    assert_no_difference "TicketItem.count" do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
        params: { payment_method_id: pm.id, coupon: "EXPIRED" }, headers: auth_headers(buyer)
    end
    assert_response :unprocessable_entity
    assert_match "coupon is not available", json_response["error"]
    assert_equal 5, ticket.reload.quantity # reservation released
  end

  test "rsvp with a usage-exhausted coupon is rejected outright" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, code: "MAXED", discount_type: "ratio", discount: 5000, max_allowed_usages: 1, order_usage_count: 1)
    buyer = create_user

    assert_no_difference "TicketItem.count" do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
        params: { payment_method_id: pm.id, coupon: "MAXED" }, headers: auth_headers(buyer)
    end
    assert_response :unprocessable_entity
    assert_equal 1, coupon.reload.order_usage_count # unchanged
    assert_equal 5, ticket.reload.quantity
  end

  test "rsvp respects ticket quantity and rejects once sold out" do
    ticket = create_ticket(event: @event, quantity: 1)
    buyer1 = create_user
    buyer2 = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer1)
    assert_response :success
    assert_equal 0, ticket.reload.quantity

    assert_no_difference "TicketItem.count" do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer2)
    end
    assert_response :unprocessable_entity
    assert_match "run out of ticket", json_response["error"]
    assert_equal 0, ticket.reload.quantity
  end

  test "rsvp rejects when the event is closed" do
    @event.update_column(:status, "closed")
    ticket = create_ticket(event: @event)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "event closed", json_response["error"]
  end

  test "rsvp rejects once venue capacity is exceeded" do
    place = create_place
    venue = create_venue(group: @group, owner: @owner, place: place, capacity: 1)
    @event.update!(venue: venue, participant_count: 1)
    ticket = create_ticket(event: @event)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "exceed venue capacity", json_response["error"]
  end

  test "rsvp revives a cancelled participant instead of creating a duplicate row" do
    ticket = create_ticket(event: @event)
    buyer = create_user
    participant = create_participant(event: @event, user: buyer, status: "cancelled")

    assert_no_difference "Participant.count" do
      post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    end
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "rsvp on a succeeded group ticket auto-joins the buyer to the group" do
    @group.update!(group_ticket_event_id: @event.id)
    ticket = create_ticket(event: @event) # free -> succeeds immediately, inherits ticket_type group
    buyer = create_user

    assert_not @group.memberships.exists?(user: buyer)
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success

    assert_equal "group", json_response["ticket_item"]["ticket_type"]
    assert @group.memberships.exists?(user: buyer)
  end

  test "rsvp 404s for an unknown ticket" do
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/does-not-exist/rsvp", headers: auth_headers(buyer)
    assert_response :not_found
  end

  test "rsvp releases the reserved quantity when payment_method_id doesn't match" do
    ticket = create_ticket(event: @event, quantity: 5)
    create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: "nonexistent" }, headers: auth_headers(buyer)

    assert_equal 5, ticket.reload.quantity # not decremented, or released back
  end

  test "rsvp releases the reserved quantity when the requested chain isn't supported by the payment method" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: nil, chains: ["base"], price: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "polygon" }, headers: auth_headers(buyer)

    assert_equal 5, ticket.reload.quantity
  end

  # ---------------------------------------------------------------- verify_payment

  test "verify_payment is self-only" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    other = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item_id = json_response["ticket_item"]["id"]

    post "/api/v1/tickets/verify_payment", params: { ticket_item_id: ticket_item_id, txhash: "0xdead" }, headers: auth_headers(other)
    assert_response :forbidden
  end

  test "verify_payment is idempotent when already succeeded" do
    ticket = create_ticket(event: @event) # free, immediately succeeded
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    ticket_item_id = json_response["ticket_item"]["id"]

    post "/api/v1/tickets/verify_payment", params: { ticket_item_id: ticket_item_id }, headers: auth_headers(buyer)
    assert_response :success
  end

  test "verify_payment requires a txhash for pending non-stripe payments" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item_id = json_response["ticket_item"]["id"]

    post "/api/v1/tickets/verify_payment", params: { ticket_item_id: ticket_item_id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "txhash is required", json_response["error"]
  end

  test "verify_payment marks succeeded when EvmPaymentVerifier confirms the tx" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item_id = json_response["ticket_item"]["id"]

    verify_result = OpenStruct.new(success: true, error: nil)
    EvmPaymentVerifier.stub :verify, verify_result do
      post "/api/v1/tickets/verify_payment", params: { ticket_item_id: ticket_item_id, txhash: "0xdead" }, headers: auth_headers(buyer)
    end
    assert_response :success
    assert_equal "succeeded", TicketItem.find(ticket_item_id).status
  end

  test "verify_payment rejects when EvmPaymentVerifier fails" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item_id = json_response["ticket_item"]["id"]

    verify_result = OpenStruct.new(success: false, error: "bad tx")
    EvmPaymentVerifier.stub :verify, verify_result do
      post "/api/v1/tickets/verify_payment", params: { ticket_item_id: ticket_item_id, txhash: "0xdead" }, headers: auth_headers(buyer)
    end
    assert_response :unprocessable_entity
    assert_equal "pending", TicketItem.find(ticket_item_id).status
  end

  # ---------------------------------------------------------------- cancel_unpaid_item

  test "cancel_unpaid_item only works on pending items, releases quantity, and refunds coupon usage" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, code: "CANCELCOUPON", discount_type: "amount", discount: 100)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "CANCELCOUPON" }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal "pending", ticket_item.status
    assert_equal 4, ticket.reload.quantity
    assert_equal 1, coupon.reload.order_usage_count

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id },
      headers: auth_headers(buyer)
    assert_response :success

    assert_equal "cancelled", ticket_item.reload.status
    assert_equal 5, ticket.reload.quantity # released back
    assert_equal 0, coupon.reload.order_usage_count # usage consumed at RSVP is refunded on cancel
  end

  test "cancel_unpaid_item is self-only" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user
    other = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id },
      headers: auth_headers(other)
    assert_response :forbidden
  end

  test "cancel_unpaid_item no-ops (ok) for a non-pending item" do
    ticket = create_ticket(event: @event)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer) # free, succeeded
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id },
      headers: auth_headers(buyer)
    assert_response :success
    assert_equal "only for pending ticket_item", json_response["message"]
    assert_equal "succeeded", ticket_item.reload.status
  end

  test "cancel_unpaid_item accepts a bare ticket_item_id, which is the only way to reach a card order" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { ticket_item_id: ticket_item.id }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal "cancelled", ticket_item.reload.status
  end

  test "cancel_unpaid_item does not tell a stranger the status of someone else's order" do
    ticket = create_ticket(event: @event)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer) # free → succeeded
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { ticket_item_id: ticket_item.id }, headers: auth_headers(create_user)
    assert_response :forbidden
  end

  test "cancelling an unpaid order lets the buyer start over on the same ticket" do
    ticket = create_ticket(event: @event, quantity: 1)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    first_item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal 0, ticket.reload.quantity

    # While that order is live, a second one is refused — one seat, one hold.
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "already have an unpaid order", json_response["error"]

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { ticket_item_id: first_item.id }, headers: auth_headers(buyer)
    assert_response :success
    # The abandoned attempt gives everything back: the unit, the seat, and the
    # participant row — which is precisely what makes the retry below legal.
    assert_equal 1, ticket.reload.quantity
    assert_equal "cancelled", Participant.find_by(event: @event, user: buyer).status

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    assert_response :success
    second_item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_not_equal first_item.id, second_item.id
    assert_equal "pending", second_item.status
    # Still one participant row, reused — (user, event) is unique.
    assert_equal 1, Participant.where(event: @event, user: buyer).count
    assert_equal "attending", Participant.find_by(event: @event, user: buyer).status
  end

  test "withdrawing from a free ticket event lets the person register again" do
    ticket = create_ticket(event: @event, quantity: 2)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    participant = Participant.find_by(event: @event, user: buyer)
    assert_equal "attending", participant.status
    assert_equal 1, ticket.reload.quantity

    delete "/api/v1/events/#{@event.id}/participants/#{participant.id}", headers: auth_headers(buyer)
    assert_response :no_content
    assert_equal "cancelled", participant.reload.status
    assert_equal 2, ticket.reload.quantity, "a free order retired on withdrawal gives its unit back"

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  # ---------------------------------------------------------------- set_payment_status

  test "set_payment_status requires the correct NEXT_TOKEN" do
    ENV["NEXT_TOKEN"] = "test-secret"
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/set_payment_status",
      params: { next_token: "wrong", chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 1000 }
    assert_response :forbidden
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "set_payment_status marks succeeded with the correct token, sufficient amount, and a verified tx" do
    ENV["NEXT_TOKEN"] = "test-secret"
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    EvmPaymentVerifier.stub :verify, OpenStruct.new(success: true, error: nil) do
      post "/api/v1/tickets/set_payment_status",
        params: { next_token: "test-secret", chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 1000, txhash: "0xfeed" }
    end
    assert_response :success
    assert_equal "succeeded", ticket_item.reload.status
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "set_payment_status refuses to mark a crypto item paid without a txhash (no free tickets)" do
    ENV["NEXT_TOKEN"] = "test-secret"
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/set_payment_status",
      params: { next_token: "test-secret", chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 1000 }
    assert_response :unprocessable_entity
    assert_equal "pending", ticket_item.reload.status
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "set_payment_status rejects an amount below the recorded amount" do
    ENV["NEXT_TOKEN"] = "test-secret"
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/set_payment_status",
      params: { next_token: "test-secret", chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 500 }
    assert_response :unprocessable_entity
    assert_equal "pending", ticket_item.reload.status
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "set_payment_status is idempotent when already succeeded" do
    ENV["NEXT_TOKEN"] = "test-secret"
    ticket = create_ticket(event: @event)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer) # free -> succeeded
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    post "/api/v1/tickets/set_payment_status",
      params: { next_token: "test-secret", chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 0 }
    assert_response :success
    assert_equal "skip verify succeeded ticket_item", json_response["message"]
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  # ---------------------------------------------------------------- index

  test "index (GET /events/:event_id/tickets) includes payment_methods" do
    ticket = create_ticket(event: @event)
    create_payment_method(item: ticket, chain: "stripe", price: 1000)

    get "/api/v1/events/#{@event.id}/tickets", headers: auth_headers(@owner)
    assert_response :success

    body = json_response["data"].find { |t| t["id"] == ticket.id }
    assert body["payment_methods"].present?, "expected payment_methods on the ticket index response"
  end

  # ---------------------------------------------------------------- add_group_ticket_item / list_group_ticket_types

  test "add_group_ticket_item immediately succeeds and grants membership for a known email" do
    @group.update!(group_ticket_event_id: @event.id)
    ticket = create_ticket(event: @event, content: "Yearly Pass", group_id: @group.id, ticket_type: "group")
    known_user = create_user(email: "known@test.com")

    post "/api/v1/tickets/add_group_ticket_item",
      params: { group_id: @group.nickname, email: "known@test.com", title: "Yearly Pass" },
      headers: auth_headers(@owner)
    assert_response :success

    ti = TicketItem.find_by(ticket: ticket, selector_address: "known@test.com")
    assert_equal "succeeded", ti.status
    assert_equal known_user.id, ti.user_id
    assert @group.memberships.exists?(user: known_user)
    assert_equal %w[ticket_granted], ti.ticketing_activities.map(&:action)
  end

  # This path used to do `update(status: "succeeded")` directly — the only
  # place in the codebase that bypassed transition!. It therefore skipped the
  # allowed-transition table entirely, so re-granting to an email whose order
  # had expired silently resurrected a closed order whose seat and coupon had
  # already been handed back.
  test "granting a group ticket cannot resurrect a closed order" do
    @group.update!(group_ticket_event_id: @event.id)
    ticket = create_ticket(event: @event, content: "Yearly Pass", group_id: @group.id, ticket_type: "group")
    user = create_user(email: "expired@test.com")
    closed = TicketItem.create!(ticket: ticket, event: @event, user: user, ticket_type: "group",
      group_id: @group.id, status: "timeout", selector_type: "email", selector_address: "expired@test.com",
      auth_type: "invite")

    post "/api/v1/tickets/add_group_ticket_item",
      params: { group_id: @group.nickname, email: "expired@test.com", title: "Yearly Pass" },
      headers: auth_headers(@owner)

    assert_response :unprocessable_entity
    assert_equal "timeout", closed.reload.status, "a terminal order must stay terminal"
  end

  test "add_group_ticket_item creates a pending ticket-carrying GroupInvite for an unknown email" do
    @group.update!(group_ticket_event_id: @event.id)
    ticket = create_ticket(event: @event, content: "Yearly Pass", group_id: @group.id, ticket_type: "group")

    post "/api/v1/tickets/add_group_ticket_item",
      params: { group_id: @group.nickname, email: "unknown@test.com", title: "Yearly Pass" },
      headers: auth_headers(@owner)
    assert_response :success

    invite = GroupInvite.find_by(group: @group, receiver_address: "unknown@test.com")
    assert_equal ticket.id, invite.ticket_id
    assert_equal "sending", invite.status
    assert_nil TicketItem.find_by(selector_address: "unknown@test.com")
  end

  test "signing up with an emailed ticket grant auto-accepts it: membership + succeeded TicketItem" do
    @group.update!(group_ticket_event_id: @event.id)
    ticket = create_ticket(event: @event, content: "Yearly Pass", group_id: @group.id, ticket_type: "group")
    post "/api/v1/tickets/add_group_ticket_item",
      params: { group_id: @group.nickname, email: "newcomer@test.com", title: "Yearly Pass" },
      headers: auth_headers(@owner)
    assert_response :success

    user = User.create!(email: "newcomer@test.com")
    GroupInvite.auto_accept_ticket_invites_for(user)

    invite = GroupInvite.find_by(group: @group, receiver_address: "newcomer@test.com")
    assert_equal "accepted", invite.status
    assert_equal user.id, invite.receiver_id
    assert @group.memberships.exists?(user: user)

    ti = TicketItem.find_by(ticket: ticket, selector_address: "newcomer@test.com")
    assert_equal "succeeded", ti.status
    assert_equal user.id, ti.user_id
  end

  test "a plain (non-ticket) pending invite does not auto-accept on signup" do
    invite = GroupInvite.create!(group: @group, role: "member", receiver_address_type: "email",
      receiver_address: "plain@test.com", status: "sending", expires_at: 30.days.from_now)

    user = User.create!(email: "plain@test.com")
    GroupInvite.auto_accept_ticket_invites_for(user)

    assert_equal "sending", invite.reload.status
    assert_not @group.memberships.exists?(user: user)
  end

  test "add_group_ticket_item requires group admin" do
    @group.update!(group_ticket_event_id: @event.id)
    create_ticket(event: @event, content: "Yearly Pass", group_id: @group.id, ticket_type: "group")
    outsider = create_user

    post "/api/v1/tickets/add_group_ticket_item",
      params: { group_id: @group.nickname, email: "x@test.com", title: "Yearly Pass" },
      headers: auth_headers(outsider)
    assert_response :forbidden
  end

  test "list_group_ticket_types is public and resolves by nickname or id" do
    ticket = create_ticket(event: @event, group_id: @group.id, ticket_type: "group")

    get "/api/v1/tickets/list_group_ticket_types", params: { group_id: @group.nickname }
    assert_response :success
    assert_equal [ticket.id], json_response.map { |t| t["id"] }

    get "/api/v1/tickets/list_group_ticket_types", params: { group_id: @group.id }
    assert_response :success
    assert_equal [ticket.id], json_response.map { |t| t["id"] }
  end

  # ---------------------------------------------------------------- coupons / set_coupon / check_coupon / get_coupon / coupon_price

  test "set_coupon bulk-creates coupons on an event via nested attributes, manager-only" do
    outsider = create_user
    post "/api/v1/tickets/set_coupon",
      params: { event_id: @event.id, coupons: [{ selector_type: "code", discount_type: "ratio", discount: 1000, max_allowed_usages: 5 }] },
      headers: auth_headers(outsider)
    assert_response :forbidden

    assert_difference "Coupon.count", 1 do
      post "/api/v1/tickets/set_coupon",
        params: { event_id: @event.id, coupons: [{ selector_type: "code", discount_type: "ratio", discount: 1000, max_allowed_usages: 5 }] },
        headers: auth_headers(@owner)
    end
    assert_response :success
  end

  test "check_coupon is public and looks up by event_id + code" do
    coupon = create_coupon(event: @event, code: "PUBLICCODE")
    get "/api/v1/tickets/check_coupon", params: { event_id: @event.id, code: "PUBLICCODE" }
    assert_response :success
    assert_equal coupon.id, json_response["coupon"]["id"]
    assert_equal "PUBLICCODE", json_response["coupon"]["code"]
  end

  test "check_coupon returns nil for no match" do
    get "/api/v1/tickets/check_coupon", params: { event_id: @event.id, code: "NOPE" }
    assert_response :success
    assert_nil json_response["coupon"]
  end

  test "get_coupon requires manager and returns only id + code" do
    coupon = create_coupon(event: @event, code: "SECRETCODE")
    outsider = create_user

    get "/api/v1/tickets/get_coupon", params: { id: coupon.id }, headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/tickets/get_coupon", params: { id: coupon.id }, headers: auth_headers(@owner)
    assert_response :success
    assert_equal coupon.id, json_response["coupon_id"]
    assert_equal "SECRETCODE", json_response["code"]
  end

  test "coupon_price previews the discount without incrementing usage" do
    coupon = create_coupon(event: @event, code: "PREVIEW", discount_type: "ratio", discount: 5000)

    get "/api/v1/tickets/coupon_price", params: { code: "PREVIEW", amount: 1000 }
    assert_response :success
    assert_equal 500, json_response["amount"]
    assert_equal 0, coupon.reload.order_usage_count
  end

  test "coupon_price 404-equivalents for an unknown code" do
    get "/api/v1/tickets/coupon_price", params: { code: "NOPE", amount: 1000 }
    assert_response :unprocessable_entity
  end

  test "coupons index is manager-only" do
    create_coupon(event: @event)
    outsider = create_user

    get "/api/v1/tickets/coupons", params: { event_id: @event.id }, headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/tickets/coupons", params: { event_id: @event.id }, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, json_response.size
    # base view must never leak the redemption code
    assert_not json_response.first.key?("code")
  end

  test "coupon show is manager-only" do
    coupon = create_coupon(event: @event)
    outsider = create_user

    get "/api/v1/tickets/coupon", params: { id: coupon.id }, headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/tickets/coupon", params: { id: coupon.id }, headers: auth_headers(@owner)
    assert_response :success
  end

  test "coupon_usage is manager-only and lists ticket_items with profile info" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    coupon = create_coupon(event: @event, code: "USAGECODE", discount_type: "amount", discount: 100)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "USAGECODE" }, headers: auth_headers(buyer)

    outsider = create_user
    get "/api/v1/tickets/coupon_usage", params: { coupon_id: coupon.id }, headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/tickets/coupon_usage", params: { coupon_id: coupon.id }, headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, json_response.size
    assert_equal buyer.id, json_response.first["user"]["id"]
  end

  # ---------------------------------------------------------------- list (purchase history)

  test "list is self-only or event-manager-only" do
    ticket = create_ticket(event: @event)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)

    outsider = create_user
    get "/api/v1/tickets/list", params: { profile_handle: buyer.name, event_id: @event.id }, headers: auth_headers(outsider)
    assert_response :forbidden

    get "/api/v1/tickets/list", params: { profile_handle: buyer.name, event_id: @event.id }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal 1, json_response.size

    get "/api/v1/tickets/list", params: { profile_handle: buyer.name, event_id: @event.id }, headers: auth_headers(@owner)
    assert_response :success
  end

  # ---------------------------------------------------------------- regressions (code-review fixes)

  test "verify_payment will not mark a stripe item paid unless Stripe confirms it (no free tickets)" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])
    ticket_item.update!(txhash: "pi_unpaid", stripe_setting_id: setting.id)

    Stripe::PaymentIntent.stub :retrieve, OpenStruct.new(status: "requires_payment_method", amount: 1000) do
      post "/api/v1/tickets/verify_payment",
        params: { ticket_item_id: ticket_item.id }, headers: auth_headers(buyer)
    end
    assert_response :unprocessable_entity
    assert_equal "pending", ticket_item.reload.status
  end

  test "verify_payment marks a stripe item paid once Stripe reports the intent succeeded" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_live_k")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])
    ticket_item.update!(txhash: "pi_paid", stripe_setting_id: setting.id)

    Stripe::PaymentIntent.stub :retrieve, OpenStruct.new(status: "succeeded", amount: 1000) do
      post "/api/v1/tickets/verify_payment",
        params: { ticket_item_id: ticket_item.id }, headers: auth_headers(buyer)
    end
    assert_response :success
    assert_equal "succeeded", ticket_item.reload.status
  end

  test "verify_payment refuses a stripe item with no key snapshot (legacy rows cannot self-confirm)" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])
    ticket_item.update!(txhash: "pi_orphan") # no stripe_setting_id

    post "/api/v1/tickets/verify_payment",
      params: { ticket_item_id: ticket_item.id }, headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_equal "pending", ticket_item.reload.status
  end

  test "set_payment_status refuses stripe orders even with a valid NEXT_TOKEN" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])

    ENV["NEXT_TOKEN"] = "testtoken"
    post "/api/v1/tickets/set_payment_status", params: {
      next_token: "testtoken", chain: ticket_item.chain,
      product_id: ticket_item.event_id, item_id: ticket_item.id, amount: 1000
    }
    assert_response :forbidden
    assert_equal "pending", ticket_item.reload.status,
      "a NEXT_TOKEN holder must not be able to mint paid stripe tickets"
  ensure
    ENV.delete("NEXT_TOKEN")
  end

  test "verify_payment rejects a txhash already consumed by another succeeded item (no replay)" do
    ticket = create_ticket(event: @event)
    pm = create_payment_method(item: ticket, chain: "base", kind: "crypto", price: 1000, chains: ["base"], token_address: "0xAAA", receiver_address: "0xBBB")
    first = create_user
    second = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(first)
    first_item = TicketItem.find(json_response["ticket_item"]["id"])
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, chain: "base" }, headers: auth_headers(second)
    second_item = TicketItem.find(json_response["ticket_item"]["id"])

    EvmPaymentVerifier.stub :verify, OpenStruct.new(success: true, error: nil) do
      post "/api/v1/tickets/verify_payment",
        params: { ticket_item_id: first_item.id, txhash: "0xshared" }, headers: auth_headers(first)
      assert_response :success

      post "/api/v1/tickets/verify_payment",
        params: { ticket_item_id: second_item.id, txhash: "0xshared" }, headers: auth_headers(second)
    end
    assert_response :unprocessable_entity
    assert_match "already used", json_response["error"]
    assert_equal "pending", second_item.reload.status
  end

  # (The old platform-wide stripe_callback endpoint is gone — webhook flows,
  # including group auto-join and late-delivery protection, are covered in
  # test/controllers/api/v1/stripe_webhooks_controller_test.rb and
  # test/jobs/stripe_webhook_job_test.rb.)

  test "rsvp blocks a badge-gated ticket for a user without the badge, allows a holder" do
    badge_class = create_badge_class(creator: @owner)
    ticket = create_ticket(event: @event, check_badge_class_id: badge_class.id)
    outsider = create_user
    holder = create_user
    create_badge(badge_class: badge_class, creator: @owner, owner: holder)

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(outsider)
    assert_response :forbidden
    assert_match "requires a badge", json_response["error"]

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(holder)
    assert_response :success
  end

  test "coupon_price does not 500 on a coupon with a nil max_allowed_usages" do
    create_coupon(event: @event, code: "UNLIMITED", discount_type: "amount", discount: 100, max_allowed_usages: nil)

    get "/api/v1/tickets/coupon_price", params: { code: "UNLIMITED", amount: 1000 }
    assert_response :success
  end

  test "rsvp succeeds with a nil-max-usage coupon instead of raising" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    create_coupon(event: @event, code: "NILMAX", discount_type: "amount", discount: 100, max_allowed_usages: nil)
    buyer = create_user

    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id, coupon: "NILMAX" }, headers: auth_headers(buyer)
    assert_response :success
    assert_equal 900, json_response["ticket_item"]["amount"] # 1000 - 100 (stripe: no x10000 scaling)
  end

  test "rsvp on a ticket that is not on sale is rejected" do
    ticket = create_ticket(event: @event, status: "nosale")
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp", headers: auth_headers(buyer)
    assert_response :unprocessable_entity
    assert_match "not on sale", json_response["error"]
  end

  test "cancelling an rsvp decrements the event participant_count" do
    ticket = create_ticket(event: @event, quantity: 5)
    pm = create_payment_method(item: ticket, chain: "stripe", price: 1000)
    buyer = create_user
    post "/api/v1/events/#{@event.id}/tickets/#{ticket.id}/rsvp",
      params: { payment_method_id: pm.id }, headers: auth_headers(buyer)
    ticket_item = TicketItem.find(json_response["ticket_item"]["id"])
    assert_equal 1, @event.reload.participant_count

    post "/api/v1/tickets/cancel_unpaid_item",
      params: { chain: ticket_item.chain, product_id: ticket_item.event_id, item_id: ticket_item.id },
      headers: auth_headers(buyer)
    assert_response :success
    assert_equal 0, @event.reload.participant_count, "capacity counter must drop when the reservation is released"
  end

  # ---------------------------------------------------------------- create / index

  test "create adds a ticket type to the event, manager-only" do
    outsider = create_user

    assert_no_difference -> { @event.tickets.count } do
      post "/api/v1/events/#{@event.id}/tickets", params: { ticket: { title: "GA", ticket_type: "event" } },
        headers: auth_headers(outsider)
    end
    assert_response :forbidden

    assert_difference -> { @event.tickets.count }, 1 do
      post "/api/v1/events/#{@event.id}/tickets", params: { ticket: { title: "GA", ticket_type: "event" } },
        headers: auth_headers(@owner)
    end
    assert_response :created
    assert_equal "GA", json_response["title"]
  end

  test "create builds nested payment_methods for a paid ticket" do
    setting = StripeSetting.create!(user: @owner, name: "K", secret_key: "sk_test_k")
    post "/api/v1/events/#{@event.id}/tickets", params: {
      ticket: {
        title: "Paid", ticket_type: "event",
        payment_methods_attributes: [{ chain: "stripe", kind: "fiat", price: 2500, stripe_setting_id: setting.id }]
      }
    }, headers: auth_headers(@owner)
    assert_response :created

    ticket = Ticket.find(json_response["id"])
    assert_equal 1, ticket.payment_methods.count
    pm = ticket.payment_methods.first
    assert_equal "stripe", pm.chain
    assert_equal 2500, pm.price
  end

  test "create rejects an invalid status with 422" do
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Bad", ticket_type: "event", status: "bogus" } },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "create rejects an invalid ticket_type with 422" do
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Bad", ticket_type: "spaceship" } },
      headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "index lists the event's tickets and 404s for an unknown event" do
    create_ticket(event: @event, title: "One")
    create_ticket(event: @event, title: "Two")

    get "/api/v1/events/#{@event.id}/tickets", headers: auth_headers(@owner)
    assert_response :success
    assert_equal 2, json_response["data"].size

    get "/api/v1/events/does-not-exist/tickets", headers: auth_headers(@owner)
    assert_response :not_found
  end

  # ------------------------------------------------------------ order_summary

  test "order_summary breaks gross down by rail and nets refunds out of wechat's withdrawable_amount" do
    ticket = create_ticket(event: @event, quantity: 10)
    buyer = create_user
    wechat_item = TicketItem.create!(ticket: ticket, event: @event, user: buyer, ticket_type: "event",
      status: "partially_refunded", amount: 10_000, currency: "cny", payment_provider: "wechat")
    Refund.create!(ticket_item: wechat_item, requested_by: @owner, amount: 4_000, status: "succeeded")
    TicketItem.create!(ticket: ticket, event: @event, user: buyer, ticket_type: "event",
      status: "succeeded", amount: 500, currency: "usd", payment_provider: "stripe")

    get "/api/v1/tickets/order_summary", params: { event_id: @event.id }, headers: auth_headers(@owner)
    assert_response :success

    wechat_row = json_response["summary"].find { |r| r["payment_provider"] == "wechat" }
    stripe_row = json_response["summary"].find { |r| r["payment_provider"] == "stripe" }

    # gross_amount is deliberately NOT netted — it mirrors the order's own
    # original amount, same as the order list.
    assert_equal 10_000, wechat_row["gross_amount"]
    # withdrawable_amount IS netted: 96% of (10_000 - 4_000) = 5_760.
    assert_equal 5_760, wechat_row["withdrawable_amount"]

    assert_equal 500, stripe_row["gross_amount"]
    assert_nil stripe_row["withdrawable_amount"]
  end

  test "order_summary requires event-manager access" do
    outsider = create_user
    get "/api/v1/tickets/order_summary", params: { event_id: @event.id }, headers: auth_headers(outsider)
    assert_response :forbidden
  end

  # ------------------------------------------------------- wechat organizer gate

  test "a plain member cannot create a wechat-paid ticket even for their own event" do
    create_wechat_pay_setting
    member = create_user
    create_membership(user: member, group: @group, role: "member")
    event = create_event(group: @group, owner: member)

    post "/api/v1/events/#{event.id}/tickets",
      params: { ticket: { title: "Paid", ticket_type: "event",
        payment_methods_attributes: [ { chain: "wechat", kind: "fiat", price: 100 } ] } },
      headers: auth_headers(member)
    assert_response :unprocessable_entity
    assert_match(/group manager or owner/, json_response["error"])
    assert_not event.tickets.exists?
  end

  test "a manager cannot create a wechat-paid ticket for an event owned by a plain member" do
    create_wechat_pay_setting
    manager = create_user
    create_membership(user: manager, group: @group, role: "manager")
    member = create_user
    create_membership(user: member, group: @group, role: "member")
    event = create_event(group: @group, owner: member)

    post "/api/v1/events/#{event.id}/tickets",
      params: { ticket: { title: "Paid", ticket_type: "event",
        payment_methods_attributes: [ { chain: "wechat", kind: "fiat", price: 100 } ] } },
      headers: auth_headers(manager)
    assert_response :unprocessable_entity
    assert_match(/event owner must be/, json_response["error"])
  end

  test "a manager can create a wechat-paid ticket when the event owner is also a manager/owner" do
    create_wechat_pay_setting
    post "/api/v1/events/#{@event.id}/tickets",
      params: { ticket: { title: "Paid", ticket_type: "event",
        payment_methods_attributes: [ { chain: "wechat", kind: "fiat", price: 100 } ] } },
      headers: auth_headers(@owner)
    assert_response :created
  end

  test "a stripe-only ticket is unaffected by the wechat organizer gate" do
    member = create_user
    create_membership(user: member, group: @group, role: "member")
    event = create_event(group: @group, owner: member)

    post "/api/v1/events/#{event.id}/tickets",
      params: { ticket: { title: "Free", ticket_type: "event" } },
      headers: auth_headers(member)
    assert_response :created
  end
end
