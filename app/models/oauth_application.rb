class OauthApplication < ApplicationRecord
  belongs_to :owner, class_name: "User", foreign_key: "owner_id"
  belongs_to :group, optional: true
  has_many :oauth_authorization_codes, foreign_key: "application_id", dependent: :destroy
  has_many :oauth_access_tokens, foreign_key: "application_id", dependent: :destroy
  has_many :oauth_refresh_tokens, foreign_key: "application_id", dependent: :destroy
  has_many :oauth_grants, foreign_key: "application_id", dependent: :destroy

  # Every scope this deployment can issue. Phase 1 opens all of them
  # (design/OAUTH_PROVIDER_PLAN.md §8) — an app still only gets what its own
  # allowed_scopes list, the user's consent, AND Pundit all permit.
  VALID_SCOPES = %w[
    openid profile email phone wallet
    groups:read events:read badges:read tickets:read
  ].freeze

  # Anyone with an account may register an app and activate it without review,
  # so the consent screen is the only thing standing between a user and a
  # phishing client. A name that reads as first-party defeats it entirely —
  # "Social Layer 登录" asking for tickets:read is indistinguishable from us.
  # Platform admins are exempt because they are who register the real ones.
  # Word-bounded, not substring: a bare /sola/i would also reject "Solana
  # Wallet" and "Solar Punk Club", which impersonate nothing.
  RESERVED_NAME_PATTERNS = [
    /\bsola\b/i, /social\s*layer/i, /\bjuluo\b/i, /聚落/, /社交层/
  ].freeze

  # Per-owner cap, so the免审核 registration path can't be used to mass-produce
  # lookalike clients faster than anyone can disable them.
  MAX_PER_OWNER = 10

  validates :name, presence: true, length: { maximum: 100 }
  validates :client_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[draft active disabled] }
  validates :redirect_uris, presence: true, if: -> { status == "active" }
  validate :redirect_uris_are_valid
  validate :scopes_are_known
  validate :name_is_not_impersonating
  validate :owner_within_app_limit, on: :create
  # A confidential client without a secret could authenticate as itself with
  # nothing at all; a public one must not have a secret to leak.
  validates :client_secret_digest, presence: true, if: :confidential?
  validates :client_secret_digest, absence: true, unless: :confidential?

  before_validation :generate_client_id, on: :create

  scope :active, -> { where(status: "active") }

  # Localhost is the one place an unencrypted redirect is legitimate: it never
  # leaves the developer's machine. Everything else must be https, or an
  # intercepted authorization code is readable in transit. (PKCE makes that code
  # unusable, but the user's identity and the fact of the authorization still
  # leak.)
  def self.redirect_uri_valid?(uri)
    parsed = URI.parse(uri.to_s)
    return false unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)
    return false if parsed.fragment.present?
    return true if parsed.scheme == "https"
    parsed.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(parsed.host)
  rescue URI::InvalidURIError
    false
  end

  def self.create_with_secret(attrs)
    raw_secret = attrs[:confidential] == false ? nil : SecureRandom.hex(32)
    app = new(attrs)
    app.client_secret_digest = BCrypt::Password.create(raw_secret) if raw_secret
    app.save!
    [ app, raw_secret ]
  end

  def rotate_secret!
    raise ArgumentError, "public clients have no secret" unless confidential?
    raw_secret = SecureRandom.hex(32)
    update!(client_secret_digest: BCrypt::Password.create(raw_secret))
    raw_secret
  end

  def authenticate_secret(secret)
    return false unless confidential?
    return false if secret.blank?
    BCrypt::Password.new(client_secret_digest).is_password?(secret)
  end

  # Exact string match, deliberately: prefix or wildcard matching on redirect
  # URIs is the classic way authorization codes get delivered to an attacker's
  # path on an otherwise legitimate host.
  def redirect_uri_allowed?(uri)
    uri.present? && redirect_uris.include?(uri)
  end

  def scopes_allowed?(requested)
    (Array(requested) - allowed_scopes).empty?
  end

  # Disabling must kill live sessions, not just prevent new ones — with no
  # review process this is the only lever against an app already in the wild.
  def disable!
    transaction do
      update!(status: "disabled")
      revoke_all_tokens!
    end
  end

  def revoke_all_tokens!
    oauth_access_tokens.where(revoked_at: nil).find_each(&:revoke!)
    oauth_refresh_tokens.where(revoked_at: nil).find_each(&:revoke!)
  end

  private

  def generate_client_id
    self.client_id ||= "sola_#{SecureRandom.hex(16)}"
  end

  def redirect_uris_are_valid
    bad = Array(redirect_uris).reject { |u| self.class.redirect_uri_valid?(u) }
    return if bad.empty?
    errors.add(:redirect_uris, "must be https (or http on localhost) with no fragment: #{bad.join(', ')}")
  end

  def scopes_are_known
    unknown = Array(allowed_scopes) - VALID_SCOPES
    errors.add(:allowed_scopes, "unknown: #{unknown.join(', ')}") if unknown.any?
  end

  def name_is_not_impersonating
    return if name.blank?
    return if owner&.platform_admin?
    return unless RESERVED_NAME_PATTERNS.any? { |re| name.match?(re) }
    errors.add(:name, "may not contain a reserved platform name")
  end

  def owner_within_app_limit
    return if owner_id.blank?
    return if owner&.platform_admin?
    return if OauthApplication.where(owner_id: owner_id).count < MAX_PER_OWNER
    errors.add(:base, "at most #{MAX_PER_OWNER} applications per user")
  end
end
