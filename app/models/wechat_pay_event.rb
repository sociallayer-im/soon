# One received WeChat Pay callback. The primary key is WeChat's own
# notification id, so a redelivery fails the insert — that unique violation IS
# the idempotency check, exactly as with StripeEvent.
#
# It carries more weight here: WeChat retries up to 15 times across 24 hours
# and counts any response slower than 5 seconds as a failure, so the same
# notification arriving several times is routine rather than exceptional.
class WechatPayEvent < ApplicationRecord
  belongs_to :wechat_pay_setting

  validates :event_type, presence: true

  scope :unprocessed, -> { where(processed_at: nil) }

  # The decrypted resource, which is where every field worth acting on lives
  # (out_trade_no, transaction_id, trade_state, amount, payer).
  def resource = payload["resource"] || {}
end
