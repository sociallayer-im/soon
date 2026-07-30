module FactoryHelpers
  def unique_suffix
    @unique_counter = (@unique_counter || 0) + 1
    "#{Process.pid}#{@unique_counter}#{rand(1000)}"
  end

  def create_user(**attrs)
    n = unique_suffix
    User.create!({
      email: "user#{n}@test.com",
      name: "user_#{n}"
    }.merge(attrs))
  end

  def create_group(owner: nil, **attrs)
    n = unique_suffix
    group = Group.create!({ name: "group_#{n}" }.merge(attrs))
    group.add_member(owner.id, "owner") if owner
    group
  end

  def create_membership(user:, group:, role: "member", **attrs)
    group.memberships.find_by(user: user) || group.add_member(user.id, role)
    Membership.find_by(user: user, group: group).tap { |m| m.update!(attrs) if attrs.any? }
  end

  def create_place(**attrs)
    n = unique_suffix
    Place.create!({ name: "Place #{n}" }.merge(attrs))
  end

  def create_venue(group:, owner:, **attrs)
    n = unique_suffix
    Venue.create!({ name: "Venue #{n}", group: group, owner: owner }.merge(attrs))
  end

  def create_track(group:, **attrs)
    n = unique_suffix
    Track.create!({ name: "Track #{n}", title: "Track #{n}", group: group }.merge(attrs))
  end

  def create_event(group:, owner:, place: nil, **attrs)
    place ||= create_place
    Event.create!({
      title: "Event #{unique_suffix}",
      start_time: 1.day.from_now,
      end_time: 1.day.from_now + 2.hours,
      group: group,
      owner: owner,
      place: place
    }.merge(attrs))
  end

  def create_participant(event:, user:, **attrs)
    Participant.create!({ event: event, user: user, status: "attending" }.merge(attrs))
  end

  def create_event_role(event:, item:, role: "member", **attrs)
    EventRole.create!({ event: event, item: item, role: role }.merge(attrs))
  end

  def create_marker(group:, place:, owner:, **attrs)
    Marker.create!({ title: "Marker #{unique_suffix}", group: group, place: place, owner: owner }.merge(attrs))
  end

  def create_group_invite(group:, **attrs)
    GroupInvite.create!({ group: group, role: "member", status: "sending" }.merge(attrs))
  end

  def create_badge_class(creator:, **attrs)
    n = unique_suffix
    BadgeClass.create!({ name: "badge-class-#{n}", title: "Badge Class #{n}", creator: creator }.merge(attrs))
  end

  def create_badge(badge_class:, creator:, owner:, **attrs)
    Badge.create!({ badge_class: badge_class, creator: creator, owner: owner, status: "minted", title: badge_class.title }.merge(attrs))
  end

  def create_voucher(sender:, badge_class:, **attrs)
    Voucher.create!({ sender: sender, badge_class: badge_class, strategy: "code", code: "CODE#{unique_suffix}", counter: 1, expires_at: 90.days.from_now }.merge(attrs))
  end

  def create_form(**attrs)
    Form.create!({ title: "Form #{unique_suffix}", published: true }.merge(attrs))
  end

  def create_form_field(form:, **attrs)
    FormField.create!({ form: form, label: "Field #{unique_suffix}", field_type: "text" }.merge(attrs))
  end

  def create_ticket(event:, **attrs)
    Ticket.create!({ title: "Ticket #{unique_suffix}", content: "content-#{unique_suffix}", event: event }.merge(attrs))
  end

  def create_payment_method(item:, **attrs)
    attrs = { item: item, chain: "stripe", kind: "fiat", price: 1000 }.merge(attrs)
    # A card method is invalid without a collecting key, so supply the event
    # owner's (creating one on demand) unless the caller pinned it.
    if Array(attrs[:chains]).push(attrs[:chain]).include?("stripe") && !attrs.key?(:stripe_setting_id)
      attrs[:stripe_setting_id] = default_stripe_setting_for(item).id
    end
    PaymentMethod.create!(attrs)
  end

  def default_stripe_setting_for(item)
    user_id = item.is_a?(User) ? item.id : item.try(:event)&.owner_id
    user_id ||= create_user.id
    StripeSetting.find_by(user_id: user_id) ||
      StripeSetting.create!(user_id: user_id, name: "Factory key", secret_key: "sk_test_factory")
  end

  def create_coupon(event:, **attrs)
    Coupon.create!({ event: event, selector_type: "code", discount_type: "ratio", discount: 1000, max_allowed_usages: 10 }.merge(attrs))
  end

  def create_recurring(**attrs)
    Recurring.create!({ start_time: 1.day.from_now, interval: "weekly" }.merge(attrs))
  end

  def create_comment(user:, item:, comment_type: "comment", **attrs)
    Comment.create!({
      user: user, item: item, comment_type: comment_type,
      content: "content-#{unique_suffix}"
    }.merge(attrs))
  end

  def create_activity(initiator:, receiver: nil, action: "badge/transfer", **attrs)
    Activity.create!({ initiator: initiator, receiver: receiver, action: action }.merge(attrs))
  end
end
