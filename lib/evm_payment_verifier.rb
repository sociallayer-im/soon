require "eth"

# Verifies an EVM on-chain payment against the receipt logs.
#
# Supports two payment patterns:
#   1. PayHub contract — emits PaymentTrasnfered(from, to, token, amount, productId, itemId)
#   2. Direct ERC-20 transfer — emits Transfer(from, to, value) on the token contract
#
# Usage:
#   result = EvmPaymentVerifier.verify(
#     txhash:           "0xabc...",
#     chain:            "base",        # ethereum | op | arb | polygon | base
#     token_address:    "0x833...",
#     receiver_address: "0xA73...",
#     amount:           10_000_000,    # in smallest token units
#     product_id:       19327,         # event_id
#     item_id:          1001234        # ticket_item.order_number
#   )
#   result.success  # => true / false
#   result.error    # => nil or String
#
class EvmPaymentVerifier
  Result = Struct.new(:success, :error, keyword_init: true)

  CHAIN_RPC = begin
    key = ENV["ALCHEMY_API_KEY"]
    {
      "ethereum" => "https://eth-mainnet.g.alchemy.com/v2/#{key}",
      "optimism" => "https://opt-mainnet.g.alchemy.com/v2/#{key}",
      "arbitrum" => "https://arb-mainnet.g.alchemy.com/v2/#{key}",
      "polygon"  => "https://polygon-mainnet.g.alchemy.com/v2/#{key}",
      "base"     => "https://base-mainnet.g.alchemy.com/v2/#{key}",
      # legacy aliases stored in old ticket_item rows
      "op"       => "https://opt-mainnet.g.alchemy.com/v2/#{key}",
      "arb"      => "https://arb-mainnet.g.alchemy.com/v2/#{key}",
    }
  end.freeze

  # keccak256("PaymentTrasnfered(address,address,address,uint256,uint256,uint256)")
  # Note: "Trasnfered" is the spelling used in the deployed contract ABI.
  PAYHUB_TOPIC = ("0x" + Eth::Util.keccak256(
    "PaymentTrasnfered(address,address,address,uint256,uint256,uint256)"
  ).unpack1("H*")).freeze

  # keccak256("Transfer(address,address,uint256)")
  TRANSFER_TOPIC = ("0x" + Eth::Util.keccak256(
    "Transfer(address,address,uint256)"
  ).unpack1("H*")).freeze

  def self.verify(txhash:, chain:, token_address:, receiver_address:, amount:, product_id:, item_id:)
    return Result.new(success: true, error: nil) if ENV["SKIP_TX_VERIFY"] == "true"

    rpc_url = CHAIN_RPC[chain.to_s]
    return Result.new(success: false, error: "unsupported chain: #{chain}") unless rpc_url

    client = build_client(rpc_url)
    raw    = client.eth_get_transaction_receipt(txhash)
    receipt = raw&.dig("result")

    return Result.new(success: false, error: "transaction not found") unless receipt
    return Result.new(success: false, error: "transaction reverted")  unless receipt["status"] == "0x1"

    logs = Array(receipt["logs"])

    if match_payhub_log?(logs, token_address, receiver_address, amount, product_id, item_id)
      return Result.new(success: true, error: nil)
    end

    if match_transfer_log?(logs, token_address, receiver_address, amount)
      return Result.new(success: true, error: nil)
    end

    Result.new(success: false, error: "no matching payment log found in tx #{txhash}")
  rescue => e
    Rails.logger.error("[EvmPaymentVerifier] #{e.class}: #{e.message}")
    Result.new(success: false, error: "rpc error: #{e.message}")
  end

  # ── private ──────────────────────────────────────────────────────────────

  def self.build_client(rpc_url)
    Eth::Client.create(rpc_url)
  end
  private_class_method :build_client

  def self.match_payhub_log?(logs, token_address, receiver_address, amount, product_id, item_id)
    logs.any? do |log|
      next unless log["topics"]&.first&.downcase == PAYHUB_TOPIC.downcase

      decoded = decode_payhub_data(log["data"])
      next unless decoded

      decoded[:to].downcase           == receiver_address.downcase &&
        decoded[:token].downcase      == token_address.downcase    &&
        decoded[:amount]              >= amount.to_i               &&
        decoded[:product_id]          == product_id.to_i           &&
        decoded[:item_id]             == item_id.to_i
    end
  end
  private_class_method :match_payhub_log?

  def self.match_transfer_log?(logs, token_address, receiver_address, amount)
    logs.any? do |log|
      next unless log["address"]&.downcase == token_address.downcase
      next unless log["topics"]&.first&.downcase == TRANSFER_TOPIC.downcase
      # Transfer(address indexed from, address indexed to, uint256 value)
      # topics[2] = to (32-byte padded); data = value
      to    = normalize_address(log.dig("topics", 2))
      value = log["data"].to_s.delete_prefix("0x").to_i(16)

      to.downcase == receiver_address.downcase && value >= amount.to_i
    end
  end
  private_class_method :match_transfer_log?

  # Decodes the PayHub event data field.
  # All 6 params are non-indexed, packed as 6 × 32-byte ABI words:
  #   [from: address][to: address][token: address][amount: uint256][productId: uint256][itemId: uint256]
  def self.decode_payhub_data(hex_data)
    hex = hex_data.to_s.delete_prefix("0x")
    return nil if hex.length < 384  # 6 × 64 hex chars

    {
      from:       normalize_address_from_word(hex[0, 64]),
      to:         normalize_address_from_word(hex[64, 64]),
      token:      normalize_address_from_word(hex[128, 64]),
      amount:     hex[192, 64].to_i(16),
      product_id: hex[256, 64].to_i(16),
      item_id:    hex[320, 64].to_i(16),
    }
  end
  private_class_method :decode_payhub_data

  # Extracts the 20-byte address from a 32-byte ABI word (64 hex chars, left-padded).
  def self.normalize_address_from_word(word64)
    "0x" + word64.last(40)
  end
  private_class_method :normalize_address_from_word

  # Extracts the 20-byte address from a 32-byte padded topic value.
  def self.normalize_address(topic)
    return "" unless topic
    "0x" + topic.delete_prefix("0x").last(40)
  end
  private_class_method :normalize_address
end
