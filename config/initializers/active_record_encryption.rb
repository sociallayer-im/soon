# Active Record encryption keys (used by `encrypts` — first consumer is the
# federation actor private keys, design/FEDERATION_PLAN.md §2.5).
#
# Keys come from env when provided; otherwise they are derived from
# secret_key_base. Derivation keeps the production deploy config unchanged
# (SECRET_KEY_BASE is already injected via ginger.yml) while still encrypting
# at rest. The derivation inputs are version-tagged strings — never change
# them, or every encrypted column becomes undecryptable.
Rails.application.config.before_initialize do |app|
  key_source = ->(purpose) do
    ActiveSupport::KeyGenerator.new(app.secret_key_base)
      .generate_key("active_record_encryption/#{purpose}/v1", 32)
      .unpack1("H*")
  end

  enc = app.config.active_record.encryption
  enc.primary_key ||= ENV["AR_ENCRYPTION_PRIMARY_KEY"] || key_source.call("primary")
  enc.deterministic_key ||= ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"] || key_source.call("deterministic")
  enc.key_derivation_salt ||= ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"] || key_source.call("salt")
end
