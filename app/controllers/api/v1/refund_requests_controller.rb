class Api::V1::RefundRequestsController < Api::BaseController
  def create
    item = TicketItem.find(params[:ticket_item_id])
    return render_error("Forbidden", status: :forbidden) unless item.user_id == current_user.id
    reason = params[:reason].to_s.strip
    return render_error("退款申请说明最多1000字") if reason.length > 1000
    outcome = item.with_lock do
      existing = item.refund_requests.open.first
      if existing
        {request: existing}
      elsif !RefundRequest.eligible?(item, current_user)
        {error: "仅活动开始前的已付款订单可申请退出与退款"}
      else
        {request: item.refund_requests.create!(user: current_user, reason: reason.presence)}
      end
    end
    return render_error(outcome[:error]) if outcome[:error]
    render json: RefundRequestBlueprint.render(outcome[:request], viewer: current_user), status: :created
  end

  def reject
    request = RefundRequest.find(params[:id])
    authorize request.ticket_item, :refund?
    reason = params[:reason].to_s.strip
    return render_error("请填写拒绝原因（最多1000字）") if reason.blank? || reason.length > 1000
    request.ticket_item.with_lock do
      request.reload
      return render_error("该退款申请已处理，请刷新订单", status: :conflict) unless request.status == "requested"
      request.update!(status: "rejected", review_reason: reason, reviewed_at: Time.current, reviewed_by: current_user)
    end
    render json: RefundRequestBlueprint.render(request, viewer: current_user)
  end
end
