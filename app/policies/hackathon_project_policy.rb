class HackathonProjectPolicy < ApplicationPolicy
  def index? = true

  # Organisers and members always; otherwise only submitted work, and only
  # once the hackathon's visibility setting lets it out (§3.3).
  def show?
    return true  if manage_hackathon?
    return true  if member?
    return false if record.flagged?
    return false unless record.submitted?

    case record.hackathon.projects_visibility
    when "always"       then true
    when "after_submit" then record.hackathon.submission_closed?
    else                     record.approved?
    end
  end

  def create?   = hackathon_policy.can_submit_project?
  def update?   = owner? || (member? && !record.submitted?)
  def destroy?  = owner? && !record.submitted?
  def submit?   = owner? && record.hackathon.submission_open? && !record.submitted?
  def unsubmit? = owner? && record.hackathon.submission_open? && record.submitted?
  def review?   = manage_hackathon?
  def award?    = manage_hackathon?
  def flag?     = manage_hackathon?

  def leave?   = member? && !owner?
  def manage_members? = owner?
  def star?    = !user.nil? && show?

  def manage_hackathon? = hackathon_policy.manage?
  def owner?  = record.owner?(user)
  def member? = record.member?(user)

  private

  def hackathon_policy
    @hackathon_policy ||= HackathonPolicy.new(user, record.hackathon)
  end
end
