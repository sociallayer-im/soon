# The instance actor's RSA keypair — a lazily-created singleton row.
class FedInstanceKey < ApplicationRecord
  encrypts :private_key

  def self.current
    first || create_singleton
  end

  # The unique index on singleton_guard (constant 0) makes a concurrent
  # first boot deterministic: one insert wins, the loser rescues and reads.
  def self.create_singleton
    key = OpenSSL::PKey::RSA.new(FederationKeyable::KEY_BITS)
    create!(private_key: key.to_pem, public_key: key.public_key.to_pem, singleton_guard: 0)
  rescue ActiveRecord::RecordNotUnique
    first
  end

  def keypair
    OpenSSL::PKey::RSA.new(private_key)
  end
end
