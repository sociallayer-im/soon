# Renders full bank details — the default view is only ever reached by a
# manager of the group whose money it is (WithdrawalsController#index scopes
# to a group the caller manages). The :admin view additionally identifies
# who requested and who settled it, for AdminWithdrawalsController.
class WithdrawalBlueprint < Blueprinter::Base
  identifier :id

  fields :amount, :currency, :status, :bank_name, :bank_account_number,
         :bank_account_name, :note, :processed_at, :created_at

  view :admin do
    fields :group_id, :user_id, :processed_by_id
    field :group_name do |w| w.group.name end
    field :requested_by do |w| w.user.nickname || w.user.name end
    field :processed_by_name do |w| w.processed_by&.nickname || w.processed_by&.name end
  end
end
