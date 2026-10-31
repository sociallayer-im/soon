class CampaignPolicy < ApplicationPolicy
  def show? = Campaign.publicly_visible.exists?(id: record.id) || update?
  def create? = !!user && GroupPolicy.new(user, record.group).manage?
  def update? = !!user && (owner?(record) || GroupPolicy.new(user, record.group).manage?)
  def destroy? = update?
end
