# A refund against an order, as the organizer's order list shows it.
#
# `status` is the whole point: a refund is asynchronous on both rails, so a row
# exists in `pending` from the moment it is requested until the provider's
# callback settles it. Rendering only succeeded ones would make a refund look
# like it never happened during exactly the window someone is watching for it.
class RefundBlueprint < Blueprinter::Base
  identifier :id

  fields :amount, :currency, :status, :full_refund, :reason, :created_at, :updated_at

  # Why a refund failed — the provider's own message. The organizer is the
  # only one who can act on it (retry, or fix it in the merchant console).
  field :error

  field :requested_by_user_id

  # The second, independent record of who ordered the refund — the first being
  # the refund_requested activity. Kept deliberately: a refund is the one
  # organizer action that moves money out, and one place to look is one place
  # to lose.
  association :requested_by, blueprint: UserBlueprint
end
