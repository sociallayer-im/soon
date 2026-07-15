class VoucherPolicy < ApplicationPolicy
  def read?   = record.sender_id == user&.id
  def update? = record.sender_id == user&.id
end
