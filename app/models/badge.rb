class Badge < ApplicationRecord
  belongs_to :badge_class
  belongs_to :owner, class_name: "User"
  belongs_to :creator, class_name: "User"
  belongs_to :voucher, optional: true

  enum :status, { minted: "minted", burned: "burned", accepted: "accepted" }
  enum :display, { normal: "normal", hidden: "hidden", pinned: "pinned" }

  validates :end_time, comparison: { greater_than: :start_time }, allow_nil: true

  def gen_swap_code
    JwtService.encode({ "badge_id" => id, "auth_type" => "swap" })
  end

  def self.decode_swap_code(swap_token)
    JwtService.decode(swap_token)["badge_id"]
  end
end
