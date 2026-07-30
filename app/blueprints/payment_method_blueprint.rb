class PaymentMethodBlueprint < Blueprinter::Base
  identifier :id

  fields :chain, :kind, :token_name, :token_address, :chain_token_addresses, :receiver_address, :price, :protocol, :chains

  # Which key collects (an id only — the key itself never leaves the server);
  # the ticket editor needs it to show the current selection.
  field :stripe_setting_id
end
