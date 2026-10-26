class ReviewBlueprint < Blueprinter::Base
  identifier :id
  fields :campaign_id, :round, :scope, :status, :note, :snapshot, :decided_by_id, :created_at, :updated_at
end
