class PlaceBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :address, :latitude, :longitude, :description, :data, :created_at
end
