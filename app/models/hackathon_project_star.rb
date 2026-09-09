class HackathonProjectStar < ApplicationRecord
  belongs_to :project, class_name: "HackathonProject", inverse_of: :hackathon_project_stars
  belongs_to :user

  validates :user_id, uniqueness: { scope: :project_id }

  after_commit :refresh_project_count!, on: %i[create destroy]

  private

  def refresh_project_count!
    HackathonProject.find_by(id: project_id)&.refresh_counts!
  end
end
