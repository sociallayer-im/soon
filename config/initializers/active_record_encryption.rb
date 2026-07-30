# Active Record encryption — used by StripeSetting (secret_key,
# webhook_secret). Keys come from the environment in production (generate a
# set with `bin/rails db:encryption:init` and add them to the deploy secrets;
# see .env.example). Dev/test fall back to keys derived from secret_key_base
# so the encrypted columns just work locally — never rely on that for real
# secrets.
#
# Rotating or losing these keys makes every stored Stripe key unreadable;
# treat them like JWT_SECRET (see .env.production's warning header).
Rails.application.configure do
  if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
    config.active_record.encryption.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
  elsif !Rails.env.production?
    base = Rails.application.secret_key_base
    config.active_record.encryption.primary_key = base[0, 32]
    config.active_record.encryption.deterministic_key = base[-32, 32]
    config.active_record.encryption.key_derivation_salt = base[0, 32]
  end
  # Production without the env keys: encryption stays unconfigured and any
  # StripeSetting write raises — acceptable while STRIPE_ENABLED is unset
  # (CN), and loud rather than silent where it matters (SG must set them).
end
