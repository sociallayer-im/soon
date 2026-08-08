# One WeChat Pay merchant account (design/WECHAT_INTEGRATION.md §2.2).
#
# CN runs the single-merchant model: exactly one platform-owned row, created
# from the environment by `rails wechat_pay:install`. Organizers do not choose
# a merchant the way they choose a Stripe key — there is only one — so
# PaymentMethod fills it in rather than asking.
#
# Credentials are stored here rather than read from ENV at call time for the
# same reason Stripe's keys are: an order snapshots the row it was collected
# by, and a refund months later has to be signed by *that* merchant's key even
# if the environment has since been rotated or repointed.
class WechatPaySetting < ApplicationRecord
  belongs_to :user, optional: true
  has_many :payment_methods, dependent: nil
  has_many :wechat_pay_events, dependent: :destroy

  validates :name, :mchid, :app_id, :cert_serial, :private_key, :apiv3_key, presence: true
  validates :status, inclusion: { in: %w(active invalid) }
  validates :currency, presence: true
  # WeChat's APIv3 key is a literal 32-byte AES-256 key, not a passphrase to
  # stretch. A wrong length fails at decrypt time inside a webhook, where the
  # only symptom is callbacks silently erroring — catch it at save instead.
  validate :apiv3_key_is_32_bytes
  validate :private_key_parses

  # The merchant every CN order collects to. Platform-owned means user_id nil;
  # a future 服务商 rollout adds per-organizer rows, which this deliberately
  # does not return.
  def self.platform_default
    where(user_id: nil, status: "active").order(:created_at).first
  end

  # 服务商 mode routes money to a sub-merchant; single-merchant mode does not.
  # Every request builder branches on this rather than on a config flag, so a
  # half-configured row cannot produce a request that means something else.
  def service_provider? = sub_mchid.present?

  # The account money actually settles to.
  def collecting_mchid = sub_mchid.presence || mchid

  def rsa_private_key = OpenSSL::PKey::RSA.new(private_key)

  # WeChat now issues a "微信支付公钥" (PUB_KEY_ID_…) in place of the rotating
  # platform certificate. Callbacks carry the serial in Wechatpay-Serial and we
  # verify against the matching key; a mismatch means the notification was not
  # signed by the merchant's counterpart and must not be trusted.
  def notify_public_key
    return nil if public_key.blank?

    OpenSSL::PKey::RSA.new(public_key)
  end

  private

  def apiv3_key_is_32_bytes
    return if apiv3_key.blank?
    return if apiv3_key.to_s.bytesize == 32

    errors.add(:apiv3_key, "must be exactly 32 bytes (APIv3 keys are AES-256 keys, not passphrases)")
  end

  def private_key_parses
    return if private_key.blank?

    OpenSSL::PKey::RSA.new(private_key)
  rescue OpenSSL::PKey::RSAError
    errors.add(:private_key,
      "is not an RSA private key. Use apiclient_key.pem (it begins with -----BEGIN PRIVATE KEY-----), " \
      "not apiclient_cert.pem (-----BEGIN CERTIFICATE-----)")
  end
end
