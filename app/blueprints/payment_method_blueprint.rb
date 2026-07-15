class PaymentMethodBlueprint < Blueprinter::Base
  identifier :id

  fields :chain, :kind, :token_name, :receiver_address, :price, :protocol, :chains
end
