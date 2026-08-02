# RSA identity keys for a federation actor (User / Group).
#
# Lazily generated: nothing has a keypair until the actor is first exposed to
# the fediverse (webfinger hit, first follow). The generate path takes a row
# lock and re-checks under it, so concurrent first hits mint exactly one key —
# a regenerated key would break every remote signature verification against
# the cached one.
module FederationKeyable
  extend ActiveSupport::Concern

  KEY_BITS = 2048

  included do
    encrypts :fed_private_key
    encrypts :fed_ed25519_private_key
  end

  def federation_keypair!
    ensure_federation_keys!
    OpenSSL::PKey::RSA.new(fed_private_key)
  end

  def ensure_federation_keys!
    return if fed_public_key.present?
    with_lock do
      reload
      next if fed_public_key.present?
      key = OpenSSL::PKey::RSA.new(KEY_BITS)
      update!(fed_private_key: key.to_pem, fed_public_key: key.public_key.to_pem)
    end
  end

  # Second keypair, Ed25519, for FEP-8b32 object integrity proofs. Same
  # lazy/locked minting discipline as the RSA pair: the public half is a
  # Multikey multibase string, published as the actor's assertionMethod, and
  # regenerating it would orphan every proof already in the wild.
  def ed25519_signing_key!
    ensure_ed25519_keys!
    OpenSSL::PKey.read(fed_ed25519_private_key)
  end

  def ensure_ed25519_keys!
    return if fed_ed25519_public_key.present?
    with_lock do
      reload
      next if fed_ed25519_public_key.present?
      key = OpenSSL::PKey.generate_key("ED25519")
      update!(fed_ed25519_private_key: key.private_to_pem,
              fed_ed25519_public_key: Federation::Multibase.encode_ed25519_public_key(key.raw_public_key))
    end
  end
end
