class Badge < ApplicationRecord
  belongs_to :badge_class
  belongs_to :owner, class_name: "User"
  belongs_to :creator, class_name: "User"
  belongs_to :voucher, optional: true

  enum :status, { minted: "minted", burned: "burned", accepted: "accepted" }
  enum :display, { normal: "normal", hidden: "hidden", pinned: "pinned" }

  validates :end_time, comparison: { greater_than: :start_time }, allow_nil: true

  # Held == currently owned and live (not burned): the precondition for any move.
  def held?
    %w[minted accepted].include?(status)
  end

  def gen_swap_code
    JwtService.encode({ "badge_id" => id, "auth_type" => "swap" })
  end

  # Returns the badge_id only for tokens actually minted as swap codes.
  def self.decode_swap_code(swap_token)
    payload = JwtService.decode(swap_token)
    raise JwtService::Error, "not a swap token" unless payload["auth_type"] == "swap"
    payload["badge_id"]
  end
end
