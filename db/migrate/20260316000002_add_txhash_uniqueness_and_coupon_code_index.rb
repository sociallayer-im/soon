class AddTxhashUniquenessAndCouponCodeIndex < ActiveRecord::Migration[8.1]
  def change
    # A single on-chain txhash (or Stripe PaymentIntent id) must back at most one
    # order — the app-level replay guard plus this partial unique index close the
    # "one payment redeems N tickets" hole race-safely.
    add_index :ticket_items, :txhash, unique: true,
      where: "txhash IS NOT NULL", name: "index_ticket_items_on_txhash_unique"

    # coupon_price / check_coupon look coupons up by code on an unauthenticated
    # route; without this index each hit is a full-table scan.
    add_index :coupons, :code, name: "index_coupons_on_code"
  end
end
