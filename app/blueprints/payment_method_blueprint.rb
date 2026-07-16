class PaymentMethodBlueprint < Blueprinter::Base
  identifier :id

  fields :chain, :kind, :token_name, :token_address, :chain_token_addresses, :receiver_address, :price, :protocol, :chains
end
