# Never renders secret_key or webhook_secret — masked_key's four-char tail
# is the only key-derived value that may leave the model.
class StripeSettingBlueprint < Blueprinter::Base
  identifier :id

  fields :name, :mode, :status, :currency, :account_id, :created_at
  field :masked_key
  # Webhook provisioning failed → confirmations come from the sweeper only,
  # with matching latency. Surfaced so the settings UI can badge it (§6.2).
  field :delayed_confirmation do |setting|
    setting.webhook_secret.blank?
  end
end
