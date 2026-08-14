# Normalizes what people actually type — "138 0013 8000", "+86 13800138000",
# "8613800138000" — to the single canonical "+8613800138000", or nil if it
# isn't a mainland mobile. Extracted from AuthController so the group-invite
# import normalizes a pasted phone list with EXACTLY the rules sign-in uses:
# the invite's receiver_address has to match users.phone verbatim for the
# auto-join at login to find it.
module PhoneNumber
  # Mirrors AuthController: mainland mobiles only, only ever +86 — the SMS
  # gateway can't reach anything else, and sign-in is the flow every phone
  # stored here must eventually round-trip through.
  CN_MOBILE = /\A1[3-9]\d{9}\z/
  CN_COUNTRY_CODE = "+86".freeze

  def self.normalize(raw)
    raw = raw.to_s.gsub(/[\s\-()]/, "")

    digits =
      if raw.start_with?("+")
        # An explicit country code has to be +86. Without this check
        # "+14155552671" — a perfectly ordinary US number — is eleven digits
        # that satisfy CN_MOBILE by coincidence.
        return nil unless raw.start_with?(CN_COUNTRY_CODE)
        raw.delete_prefix(CN_COUNTRY_CODE)
      elsif raw.length > 11 && raw.start_with?("86")
        raw.delete_prefix("86")
      else
        raw
      end

    return nil unless digits.match?(CN_MOBILE)

    "#{CN_COUNTRY_CODE}#{digits}"
  end
end
