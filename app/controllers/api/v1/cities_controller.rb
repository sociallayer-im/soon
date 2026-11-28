class Api::V1::CitiesController < Api::BaseController
  skip_before_action :authenticate!, only: :index

  def index
    render json: { data: DiscoveryCity.options }
  end
end
