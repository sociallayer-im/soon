module Federation
  # FEP-8b32 object integrity proofs, eddsa-jcs-2022 cryptosuite
  # (W3C Data Integrity + RFC 8785 JCS + Ed25519).
  #
  # Why: HTTP signatures authenticate the *delivery*, not the object — a
  # mirrored copy of one of our events is unverifiable once it leaves the
  # origin. A proof embedded in the object survives any transport, which is
  # what makes third-party archives (and post-shutdown mirrors, PLAN §9.7)
  # attributable. Verified against Mitra/streams semantics: proof options are
  # canonicalized WITH the document's @context, hashes are
  # SHA256(proofConfig) || SHA256(document-without-proof), proofValue is
  # base58btc multibase of the raw Ed25519 signature.
  module IntegrityProof
    class Error < StandardError; end

    CRYPTOSUITE = "eddsa-jcs-2022".freeze
    KEY_FRAGMENT = "#ed25519-key".freeze

    module_function

    # Returns a copy of `document` with an embedded proof signed by `actor`
    # (a User/Group with FederationKeyable). `created` defaults to now; pass a
    # stable timestamp to make re-serialization deterministic.
    def sign(document, actor, created: Time.current)
      raise Error, "document already carries a proof" if document.key?("proof")
      key = actor.ed25519_signing_key!
      options = {
        "type" => "DataIntegrityProof",
        "cryptosuite" => CRYPTOSUITE,
        "created" => created.utc.iso8601,
        "verificationMethod" => "#{Urls.actor_url(actor)}#{KEY_FRAGMENT}",
        "proofPurpose" => "assertionMethod"
      }
      signature = key.sign(nil, hash_data(document, options))
      document.merge("proof" => options.merge("proofValue" => Multibase.encode(signature)))
    end

    # Verifies an embedded proof against `public_key_multibase`. Returns true/
    # false; raises Error only for a structurally unusable proof.
    def verify(document, public_key_multibase)
      proof = document["proof"]
      proof = proof.first if proof.is_a?(Array)
      raise Error, "no proof object" unless proof.is_a?(Hash)
      unless proof["type"] == "DataIntegrityProof" && proof["cryptosuite"] == CRYPTOSUITE
        raise Error, "unsupported proof type/cryptosuite"
      end
      value = proof["proofValue"]
      raise Error, "missing proofValue" unless value.is_a?(String)

      raw = Multibase.decode_ed25519_public_key(public_key_multibase)
      key = OpenSSL::PKey.new_raw_public_key("ED25519", raw)
      options = proof.except("proofValue")
      key.verify(nil, Multibase.decode(value), hash_data(document.except("proof"), options))
    rescue Multibase::Error, Jcs::Error, OpenSSL::PKey::PKeyError => e
      raise Error, e.message
    end

    # Best-effort verification of a remote object against its author's cached
    # actor document. Three-valued: true (verified), false (present but bad),
    # nil (no proof, or the actor advertises no usable Multikey).
    def verify_embedded(object, fed_actor)
      return nil unless object.is_a?(Hash) && object["proof"].present?
      multikey = actor_multikey(fed_actor)
      return nil if multikey.nil?
      verify(object, multikey)
    rescue Error
      false
    end

    def actor_multikey(fed_actor)
      methods = fed_actor.raw&.dig("assertionMethod")
      Array(methods).filter_map { |m|
        next unless m.is_a?(Hash) && m["type"] == "Multikey"
        m["publicKeyMultibase"]
      }.first
    end

    # eddsa-jcs-2022: the proof configuration inherits the document's
    # @context (binding the proof to the same term definitions), then
    # hashData = SHA256(JCS(config)) || SHA256(JCS(document)).
    def hash_data(document, options)
      config = options.dup
      config["@context"] = document["@context"] if document.key?("@context")
      OpenSSL::Digest::SHA256.digest(Jcs.canonicalize(config)) +
        OpenSSL::Digest::SHA256.digest(Jcs.canonicalize(document))
    end
  end
end
