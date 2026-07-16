class VenueBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :capacity, :website, :about, :amenities, :tags, :featured_image_url

  view :with_availability do
    association :availabilities, blueprint: AvailabilityBlueprint
  end
end
