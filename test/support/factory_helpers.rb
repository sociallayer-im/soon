module FactoryHelpers
  # One throwaway keypair per process. 2048-bit generation costs ~100ms and
  # every WeChat Pay test needs a key that actually signs and verifies, so a
  # fixed PEM constant would be the alternative — and a real RSA key in the
  # repo is exactly the thing we tell people not to commit.
  def self.rsa_key
    @rsa_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  # Bounded on purpose: a user/group name is capped at 20 characters
  # (HandleName), and "user-" plus this has to fit. pid is folded to five
  # digits so a high pid on a busy machine cannot push a name over the limit
  # and fail every test in the file with a validation error.
  def unique_suffix
    @unique_counter = (@unique_counter || 0) + 1
    "#{Process.pid % 100_000}#{@unique_counter}#{rand(1000)}"
  end

  def create_user(**attrs)
    n = unique_suffix
    User.create!({
      email: "user#{n}@test.com",
      name: "user-#{n}"
    }.merge(attrs))
  end

  def create_group(owner: nil, **attrs)
    n = unique_suffix
    group = Group.create!({ name: "group-#{n}" }.merge(attrs))
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

  def create_team(group:, users: [], **attrs)
    n = unique_suffix
    team = Team.create!({ name: "Team #{n}", slug: "team-#{n}", group: group }.merge(attrs))
    users.each { |u| TeamMembership.create!(team: team, user: u) }
    team
  end

  def create_category(group:, **attrs)
    n = unique_suffix
    Category.create!({ name: "Board #{n}", slug: "board-#{n}", group: group }.merge(attrs))
  end

  def create_topic(category:, user:, **attrs)
    Topic.create!({
      title: "Topic #{unique_suffix}",
      content: "body",
      category: category,
      group: category.group,
      user: user
    }.merge(attrs))
  end

  def create_reply(topic:, user:, **attrs)
    Reply.create!({ content: "reply #{unique_suffix}", topic: topic, user: user }.merge(attrs))
  end

  # A choice poll with two options (A, B) unless poll_type: "number".
  def create_poll(group:, user:, options: %w[A B], **attrs)
    poll = Poll.create!({ title: "Poll #{unique_suffix}", group: group, user: user }.merge(attrs))
    unless poll.number?
      options.each_with_index { |t, i| poll.poll_options.create!(title: t, position: i) }
    end
    poll
  end

  # Published by default with an open window; the participant tier needs an
  # event, so pass one or override can_submit_project.
  def create_hackathon(group:, user:, event: nil, **attrs)
    Hackathon.create!({
      title: "Hackathon #{unique_suffix}", group: group, user: user, event: event,
      status: "published", projects_visibility: "always",
      can_submit_project: event ? "participant" : "member",
      submit_close_at: 7.days.from_now
    }.merge(attrs))
  end

  def create_hackathon_project(hackathon:, user:, **attrs)
    project = HackathonProject.create!({ title: "Project #{unique_suffix}", hackathon: hackathon, user: user }.merge(attrs))
    project.hackathon_project_members.create!(user: user, role: "owner")
    project
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

  def create_event_role(event:, item:, role: "speaker", **attrs)
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

  # The group's membership-ticket event: designated by the group's pointer,
  # which is the only signal (Event#group_ticket_event?).
  def create_group_ticket_event(group:, owner:, **attrs)
    event = create_event(group: group, owner: owner, **attrs)
    group.update!(group_ticket_event_id: event.id)
    event
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

  # The platform merchant. Signs and verifies for real (same keypair on both
  # sides), so gateway tests exercise the actual OpenSSL path rather than a
  # stub of it.
  def create_wechat_pay_setting(**attrs)
    n = unique_suffix
    WechatPaySetting.create!({
      name: "Merchant #{n}",
      mchid: "16#{n}"[0, 10],
      app_id: "wxtestappid#{n}"[0, 18],
      cert_serial: SecureRandom.hex(20).upcase,
      private_key: FactoryHelpers.rsa_key.to_pem,
      apiv3_key: SecureRandom.alphanumeric(32),
      public_key_id: "PUB_KEY_ID_#{n}",
      public_key: FactoryHelpers.rsa_key.public_key.to_pem
    }.merge(attrs))
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

  # Returns [application, raw_client_secret]. The secret is nil for public
  # clients, which is the whole point of that distinction — see
  # OauthApplication#create_with_secret.
  def create_oauth_application(owner: nil, **attrs)
    n = unique_suffix
    OauthApplication.create_with_secret({
      owner: owner || create_user,
      name: "testapp_#{n}",
      redirect_uris: [ "https://client.example.com/callback" ],
      allowed_scopes: %w[openid profile email],
      status: "active"
    }.merge(attrs))
  end

  # Installs a signing key for the duration of the block. Reuses the shared
  # process-wide keypair — OauthConfig memoizes, so it must be reset on both
  # sides or a later test inherits this one's key.
  def with_oauth_signing_key
    previous = ENV["OAUTH_RSA_PRIVATE_KEY"]
    ENV["OAUTH_RSA_PRIVATE_KEY"] = FactoryHelpers.rsa_key.to_pem
    OauthConfig.reset!
    yield
  ensure
    ENV["OAUTH_RSA_PRIVATE_KEY"] = previous
    OauthConfig.reset!
  end
end
