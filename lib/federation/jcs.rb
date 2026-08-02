module Federation
  # RFC 8785 JSON Canonicalization Scheme — the transform under FEP-8b32's
  # eddsa-jcs-2022 cryptosuite. No gem: the full RFC is mostly about float
  # serialization, and AP documents are strings/integers/booleans/objects/
  # arrays. Floats are supported for round integral values and shortest-form
  # decimals; anything requiring the exotic ES6 exponent branches raises
  # rather than silently canonicalizing wrong.
  module Jcs
    class Error < StandardError; end

    module_function

    def canonicalize(value)
      serialize(value).b
    end

    def serialize(value)
      case value
      when Hash
        # RFC 8785 §3.2.3: property names sort by UTF-16 code units, which
        # differs from Ruby's UTF-8 string order for astral-plane characters.
        pairs = value.keys.map(&:to_s).sort_by { |k| k.encode(Encoding::UTF_16BE).b }
        inner = pairs.map { |k|
          v = value.key?(k) ? value[k] : value[k.to_sym]
          "#{serialize_string(k)}:#{serialize(v)}"
        }
        "{#{inner.join(',')}}"
      when Array
        "[#{value.map { |v| serialize(v) }.join(',')}]"
      when String then serialize_string(value)
      when Integer then value.to_s
      when Float then serialize_number(value)
      when true then "true"
      when false then "false"
      when nil then "null"
      else
        raise Error, "cannot canonicalize #{value.class}"
      end
    end

    # RFC 8785 §3.2.2.2 = ECMAScript Number::toString. Integral values print
    # without a fraction; short decimals use Ruby's shortest round-trip repr,
    # which matches ES6 in the plain-notation range.
    def serialize_number(value)
      raise Error, "NaN/Infinity cannot be canonicalized" unless value.finite?
      return "0" if value.zero? # covers -0.0, which ES6 prints as "0"
      if value == value.to_i && value.abs < 1e21
        return value.to_i.to_s
      end
      s = value.to_s
      raise Error, "exponent-form float #{s} not supported" if s.include?("e")
      s
    end

    # RFC 8785 §3.2.2.2: escape only \" \\ and controls; \b \t \n \f \r get
    # short forms, other controls \u00xx lowercase hex; everything else is
    # literal UTF-8.
    ESCAPES = {
      "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\t" => "\\t",
      "\n" => "\\n", "\f" => "\\f", "\r" => "\\r"
    }.freeze

    def serialize_string(value)
      out = value.to_s.each_char.map { |c|
        if (esc = ESCAPES[c])
          esc
        elsif c.ord < 0x20
          format("\\u%04x", c.ord)
        else
          c
        end
      }.join
      "\"#{out}\""
    end
  end
end
