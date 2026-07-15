class GroupPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = !user.nil?
  def update?  = group_admin?(record)
  def destroy? = group_admin?(record)
end
