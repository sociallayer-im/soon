class Api::V1::CitiesController < Api::BaseController
  skip_before_action :authenticate!, only: :index

  def index
    render json: { data: Group.where(active: true).where.not(city: [nil, ""]).distinct.order(:city).pluck(:city) }
  end
end
