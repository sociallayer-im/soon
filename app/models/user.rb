class User < ApplicationRecord
  has_many :memberships, dependent: :delete_all
  has_many :stripe_settings, dependent: :destroy
  has_many :groups, through: :memberships
  has_many :events, foreign_key: "owner_id", dependent: :destroy
  has_many :participants, dependent: :destroy
  has_many :participated_events, through: :participants, source: :event
  has_many :markers, foreign_key: "owner_id", dependent: :destroy
  has_many :venues, foreign_key: "owner_id", dependent: :destroy
  has_many :track_roles, dependent: :destroy
  has_many :tracks, through: :track_roles
  has_many :domains, as: :item, dependent: :destroy
  has_many :created_badge_classes, class_name: "BadgeClass", foreign_key: "creator_id", dependent: :destroy
  has_many :owned_badges, class_name: "Badge", foreign_key: "owner_id", dependent: :destroy
  has_many :created_badges, class_name: "Badge", foreign_key: "creator_id", dependent: :destroy

  normalizes :email, with: ->(e) { e.strip.downcase }
  normalizes :eth,   with: ->(a) { a.strip.downcase }

  # A user signs in via at least one identity: email (code login / Google),
  # eth (SIWE wallet), sol (Solana wallet), or WeChat (CN 服务号 网页授权).
  # Wallet- and WeChat-first accounts have no email until they bind one, and no
  # name until they register one.
  validates :email, uniqueness: true, allow_nil: true
  validates :eth,   uniqueness: true, allow_nil: true
  validates :sol,   uniqueness: true, allow_nil: true
  validates :wechat_openid,  uniqueness: true, allow_nil: true
  validates :wechat_unionid, uniqueness: true, allow_nil: true
  validate  :has_login_identity

  # `name` is the user's unique identifier/username (the handle concept). It must
  # be a well-formed slug and unique (the column is uniquely indexed). It is nil
  # until the user picks one on the register screen.
  validates :name, uniqueness: true, allow_nil: true
  validates :name, format: { with: /\A[a-z0-9_]{3,30}\z/, message: "must be 3-30 lowercase letters, digits, or underscores" },
    allow_blank: true

  # Platform administrators curate cross-group content: homepage featured/top
  # tags, popup-city removal. Two markers answer to this — the `admin` boolean
  # (the current one) and "admin" in the legacy `permissions` array — because
  # the array predates the column and still carries the live admins.
  #
  # `admin` is set in the database by hand and nowhere else. It is absent from
  # UsersController's permit list on purpose — that list is a closed allowlist,
  # so there is no request, from any client, that can grant or revoke it.
  def platform_admin?
    admin? || permissions.include?("admin")
  end

  # Where platform-wide notices go (a new group registering, today). Deliberately
  # keyed on the `admin` column alone: `permissions` is an authorization legacy
  # and being able to remove a popup city is not the same as wanting mail about
  # every group that signs up. Blank addresses are dropped here rather than at
  # each call site — a wallet- or WeChat-first admin has no email to write to.
  def self.admin_emails
    where(admin: true).where.not(email: [ nil, "" ]).distinct.pluck(:email)
  end

  private def has_login_identity
    return if [ email, eth, sol, wechat_openid, wechat_unionid ].any?(&:present?)

    errors.add(:base, "must have an email, eth, sol, or wechat identity")
  end

  # Looks a user up by primary key OR unique username — API paths accept either
  # (/users/0GA2... or /users/alice). Raises RecordNotFound like find.
  def self.resolve!(identifier)
    find_by(id: identifier) || find_by!(name: identifier)
  end
end
