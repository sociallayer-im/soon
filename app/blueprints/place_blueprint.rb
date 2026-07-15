class PlaceBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :address, :latitude, :longitude, :description
end
