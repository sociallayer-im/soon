class CampaignPolicy < ApplicationPolicy
  def show? = record.status == "published" || update?
  def create? = !!user && GroupPolicy.new(user, record.group).manage?
  def update? = !!user && (owner?(record) || GroupPolicy.new(user, record.group).manage?)
  def destroy? = update?
end
