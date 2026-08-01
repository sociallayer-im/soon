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
end
