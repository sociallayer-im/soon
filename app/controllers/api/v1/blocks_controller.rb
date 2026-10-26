class Api::V1::BlocksController < Api::BaseController
  def index
    render_collection current_user.blocks.order(created_at: :desc), blueprint: BlockBlueprint
  end

  def create
    target_id = params[:target_user_id].to_s
    return render_error("cannot block yourself") if target_id == current_user.id
    return render_error("user not found", status: :not_found) unless User.exists?(id: target_id)

    block = current_user.blocks.find_by(target_user_id: target_id)
    if block
      render json: BlockBlueprint.render(block)
    else
      block = current_user.blocks.create!(target_user_id: target_id)
      render json: BlockBlueprint.render(block), status: :created
    end
  rescue ActiveRecord::RecordInvalid => e
    render_error(e.record.errors.full_messages.join(", "))
  end

  def destroy
    block = Block.find(params[:id])
    return render_error("Forbidden", status: :forbidden) unless block.user_id == current_user.id

    block.destroy!
    head :no_content
  end
end
