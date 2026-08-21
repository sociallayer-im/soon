# Platform-admin view over every WeChat withdrawal request, and the only
# place `status` moves out of "pending" — there is no transfer API behind
# Withdrawal (single-merchant WeChat Pay: see design/WECHAT_INTEGRATION.md
# §2.2), so an operator pays the bank details by hand and records the
# outcome here.
class Api::V1::AdminWithdrawalsController < Api::BaseController
  before_action :require_platform_admin!
  before_action :set_withdrawal, only: %i[update]

  # GET /api/v1/admin/withdrawals?status=
  def index
    scope = Withdrawal.includes(:user, :group, :processed_by).order(created_at: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    render_collection(scope, blueprint: WithdrawalBlueprint, view: :admin)
  end

  # PATCH /api/v1/admin/withdrawals/:id — settle or reject a pending request.
  def update
    unless %w[completed rejected].include?(params[:status])
      return render_error("status must be completed or rejected")
    end
    unless @withdrawal.status == "pending"
      return render_error("only a pending withdrawal can be settled or rejected")
    end

    attrs = { status: params[:status], processed_by: current_user, processed_at: Time.current }
    attrs[:note] = params[:note] if params[:note].present?

    if @withdrawal.update(attrs)
      render json: WithdrawalBlueprint.render_as_hash(@withdrawal, view: :admin)
    else
      render_error(@withdrawal.errors.full_messages.join(", "))
    end
  end

  private

  def set_withdrawal
    @withdrawal = Withdrawal.find(params[:id])
  end

  def require_platform_admin!
    render json: { error: "Forbidden" }, status: :forbidden unless current_user&.platform_admin?
  end
end
