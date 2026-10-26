class ReportBlueprint < Blueprinter::Base
  identifier :id
  fields :target_type, :target_id, :reason, :status, :note, :created_at, :updated_at
end
