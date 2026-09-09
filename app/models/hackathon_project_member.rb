# One person's place on one project. `hackathon_id` is copied from the
# project so the one-project-per-person-per-hackathon rule can live in a
# unique index rather than a validation (design/HACKATHON_MODULE.md §1.4).
class HackathonProjectMember < ApplicationRecord
  ROLES = %w[owner member].freeze

  belongs_to :project, class_name: "HackathonProject", inverse_of: :hackathon_project_members
  belongs_to :hackathon
  belongs_to :user

  before_validation { self.hackathon_id ||= project&.hackathon_id }

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :project_id, message: "is already on this project" }
  validates :user_id, uniqueness: { scope: :hackathon_id,
                                    message: "is already on a project in this hackathon" }

  after_commit :refresh_project_count!, on: %i[create destroy]

  private

  # Looked up, not taken from the association: destroying a project destroys
  # its members, each of which would otherwise write back to a gone record.
  def refresh_project_count!
    HackathonProject.find_by(id: project_id)&.refresh_counts!
  end
end
