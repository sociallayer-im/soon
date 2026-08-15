# Builds the UserInfo response for a granted set of scopes.
#
# The governing rule (design/OAUTH_PROVIDER_PLAN.md §3): a scope only ever
# NARROWS what a user can already see about themselves. Nothing here reads
# another user's data, and nothing here bypasses a Pundit policy — every claim
# is derived from the token owner's own record or their own memberships. That
# is what makes it safe to open all scopes in phase 1 with no app review.
class OauthClaims
  # Human-readable scope descriptions, returned by the authorize endpoint so
  # the consent screen never has to hardcode them. Keys must stay in step with
  # OauthApplication::VALID_SCOPES.
  DESCRIPTIONS = {
    "openid"       => { en: "Confirm your identity",              zh: "确认你的身份" },
    "profile"      => { en: "Your username, avatar and bio",      zh: "你的用户名、头像和简介" },
    "email"        => { en: "Your email address",                 zh: "你的邮箱地址" },
    "phone"        => { en: "Your phone number",                  zh: "你的手机号" },
    "wallet"       => { en: "Your wallet addresses",              zh: "你的钱包地址" },
    "groups:read"  => { en: "The communities you belong to",      zh: "你加入的社群" },
    "events:read"  => { en: "The events you host or attend",      zh: "你主办或参加的活动" },
    "badges:read"  => { en: "The badges you hold",                zh: "你持有的徽章" },
    # Flagged sensitive: this is a purchase history, and it is open from phase 1
    # with no app review behind it. The consent screen must call it out.
    "tickets:read" => { en: "Your tickets and purchase records",  zh: "你的票据与购买记录", sensitive: true }
  }.freeze

  def self.sensitive?(scope) = DESCRIPTIONS.dig(scope, :sensitive) == true

  def self.describe(scopes)
    Array(scopes).map do |s|
      d = DESCRIPTIONS[s] || {}
      { scope: s, en: d[:en] || s, zh: d[:zh] || s, sensitive: d[:sensitive] == true }
    end
  end

  # How many records a list-bearing scope will return. UserInfo is a single
  # unpaginated response, so each list is bounded rather than left to grow with
  # the user's history.
  LIST_LIMIT = 100

  def initialize(user, scopes)
    @user = user
    @scopes = Array(scopes)
  end

  def to_h
    claims = { sub: @user.id }
    claims.merge!(profile_claims) if scope?("profile")
    claims.merge!(email_claims)   if scope?("email")
    claims.merge!(phone_claims)   if scope?("phone")
    claims.merge!(wallet_claims)  if scope?("wallet")
    claims[:groups]  = group_claims  if scope?("groups:read")
    claims[:events]  = event_claims  if scope?("events:read")
    claims[:badges]  = badge_claims  if scope?("badges:read")
    claims[:tickets] = ticket_claims if scope?("tickets:read")
    claims
  end

  private

  def scope?(s) = @scopes.include?(s)

  def profile_claims
    {
      # OIDC's standard names first, so a generic client library populates its
      # session without any sola-specific mapping...
      preferred_username: @user.name,
      name: @user.nickname.presence || @user.name,
      picture: @user.image_url,
      updated_at: @user.updated_at.to_i,
      # ...then the name sola's own docs and SDK use.
      handle: @user.name,
      nickname: @user.nickname,
      bio: @user.bio,
      social_links: @user.social_links
    }
  end

  def email_claims
    # A wallet- or phone-first account may simply have no email. There is no
    # separate verification flag on the column because the only ways an address
    # gets there are a mailed code and Google — both already proofs of control.
    { email: @user.email, email_verified: @user.email.present? }
  end

  def phone_claims
    { phone_number: @user.phone, phone_number_verified: @user.phone.present? }
  end

  def wallet_claims
    { wallet_address: @user.eth, eth_address: @user.eth, sol_address: @user.sol }
  end

  def group_claims
    @user.memberships.where(active: true).includes(:group).limit(LIST_LIMIT).filter_map do |m|
      next if m.group.nil?
      # `name` is the handle on Group exactly as it is on User; `nickname` is
      # the display name.
      { id: m.group.id, handle: m.group.name, name: m.group.nickname.presence || m.group.name,
        image_url: m.group.image_url, role: m.role }
    end
  end

  def event_claims
    hosted = @user.events.order(start_time: :desc).limit(LIST_LIMIT)
    attending = @user.participated_events.order(start_time: :desc).limit(LIST_LIMIT)
    {
      hosted: hosted.map { |e| event_summary(e) },
      attending: attending.map { |e| event_summary(e) }
    }
  end

  def event_summary(event)
    { id: event.id, title: event.title, start_time: event.start_time, end_time: event.end_time,
      group_id: event.group_id, image_url: event.image_url }
  end

  def badge_claims
    @user.owned_badges.where(status: "minted").includes(:badge_class)
         .order(created_at: :desc).limit(LIST_LIMIT).map do |b|
      { id: b.id, title: b.title, image_url: b.image_url, badge_class_id: b.badge_class_id,
        created_at: b.created_at }
    end
  end

  def ticket_claims
    TicketItem.where(user_id: @user.id).includes(:ticket, :event)
              .order(created_at: :desc).limit(LIST_LIMIT).map do |item|
      { id: item.id, ticket_id: item.ticket_id, event_id: item.event_id,
        status: item.status, amount: item.amount, currency: item.currency,
        created_at: item.created_at }
    end
  end
end
