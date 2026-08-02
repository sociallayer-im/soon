module Federation
  # base58btc multibase ("z" prefix) and the Ed25519 Multikey codec — the
  # encodings FEP-8b32 uses for publicKeyMultibase and proofValue. Small
  # enough that a gem dependency isn't worth it.
  module Multibase
    class Error < StandardError; end

    ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze
    INDEX = ALPHABET.each_char.with_index.to_h.freeze
    ED25519_PUB_PREFIX = "\xed\x01".b.freeze # multicodec ed25519-pub, varint

    module_function

    def encode(bytes)
      "z#{base58(bytes)}"
    end

    def decode(str)
      raise Error, "not base58btc multibase: #{str.to_s[0, 8]}" unless str.is_a?(String) && str.start_with?("z")
      unbase58(str[1..])
    end

    # 32-byte raw Ed25519 public key → "z6Mk…" Multikey string
    def encode_ed25519_public_key(raw)
      raise Error, "expected 32-byte key" unless raw.bytesize == 32
      encode(ED25519_PUB_PREFIX + raw)
    end

    def decode_ed25519_public_key(multikey)
      bytes = decode(multikey)
      unless bytes.byteslice(0, 2) == ED25519_PUB_PREFIX && bytes.bytesize == 34
        raise Error, "not an ed25519-pub multikey"
      end
      bytes.byteslice(2, 32)
    end

    def base58(bytes)
      leading = bytes.each_byte.take_while(&:zero?).count
      num = bytes.unpack1("H*").to_i(16)
      out = +""
      while num.positive?
        num, rem = num.divmod(58)
        out.prepend(ALPHABET[rem])
      end
      ("1" * leading) + out
    end

    def unbase58(str)
      leading = str.each_char.take_while { |c| c == "1" }.count
      num = str.each_char.reduce(0) { |acc, c|
        digit = INDEX[c] or raise Error, "invalid base58 character #{c.inspect}"
        acc * 58 + digit
      }
      hex = num.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      body = num.zero? ? "".b : [hex].pack("H*")
      ("\x00".b * leading) + body
    end
  end
end
