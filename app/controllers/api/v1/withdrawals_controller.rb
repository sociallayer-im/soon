# Withdrawal requests against a group's pooled WeChat Pay revenue. Gated
# behind wechat_pay_enabled! the same as the rest of WeChat Pay — see
# Api::BaseController#wechat_pay_enabled?. Stripe/crypto organizers never
# need this: their money never passes through the platform (see
# design/PAYMENTS_PLAN.md), so there is nothing here for them to withdraw.
class Api::V1::WithdrawalsController < Api::BaseController
  before_action :require_wechat_pay_enabled!
  before_action :set_group, only: %i[index balance create]

  # GET /api/v1/withdrawals/groups — every group the caller manages, with
  # its current WeChat balance, so the frontend can offer a picker without
  # an N+1 round trip per group.
  def groups
    data = Withdrawal.manageable_groups(current_user).map do |group|
      {
        id: group.id,
        name: group.name,
        currency: "cny",
        available_amount: Withdrawal.available_balance(group),
        total_withdrawn: Withdrawal.total_withdrawn(group)
      }
    end
    render json: { groups: data }
  end

  # GET /api/v1/withdrawals?group_id= — every withdrawal ever requested
  # against this group's pool, by any of its managers (it's their shared
  # money, not the caller's own private history).
  def index
    render json: WithdrawalBlueprint.render(@group.withdrawals.order(created_at: :desc))
  end

  # GET /api/v1/withdrawals/balance?group_id=
  def balance
    render json: {
      group_id: @group.id,
      currency: "cny",
      available_amount: Withdrawal.available_balance(@group),
      total_withdrawn: Withdrawal.total_withdrawn(@group)
    }
  end

  # POST /api/v1/withdrawals — group_id + bank details. Always withdraws the
  # full available balance; there is no partial-amount input by design (see
  # the frontend spec).
  #
  # `@group.with_lock` takes a row lock (SELECT ... FOR UPDATE) on the group
  # for the duration of the transaction, so two requests against the SAME
  # group's pool — whether two tabs from one manager or two different
  # managers acting independently — serialize instead of both reading the
  # same available_balance and each inserting a full-amount withdrawal.
  # Locking current_user instead (an earlier version of this) only protected
  # against one person double-submitting; it did nothing for two co-managers
  # of one group, who would each see the other's un-deducted balance.
  def create
    outcome = @group.with_lock do
      amount = Withdrawal.available_balance(@group)
      next { error: "no withdrawable balance" } if amount <= 0

      withdrawal = @group.withdrawals.new(
        user: current_user,
        amount: amount,
        currency: "cny",
        status: "pending",
        bank_name: params[:bank_name],
        bank_account_number: params[:bank_account_number],
        bank_account_name: params[:bank_account_name]
      )
      withdrawal.save ? { withdrawal: withdrawal } : { error: withdrawal.errors.full_messages.join(", ") }
    end

    if outcome[:withdrawal]
      WithdrawalRequestedMailJob.perform_later(withdrawal_id: outcome[:withdrawal].id)
      render json: WithdrawalBlueprint.render(outcome[:withdrawal]), status: :created
    else
      render_error(outcome[:error])
    end
  end

  private

  def set_group
    group = Group.find_by(id: params[:group_id])
    unless group && Withdrawal.may_manage?(current_user, group)
      render_error("not authorized", status: :forbidden)
      return
    end
    @group = group
  end
end
