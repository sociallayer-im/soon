class MarkerPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = group_member?(record.group)
  def update?  = owner?(record) || group_admin?(record.group)
  def destroy? = owner?(record) || group_admin?(record.group)
end
