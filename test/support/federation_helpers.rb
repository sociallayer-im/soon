# Helpers for federation tests: a fake remote actor with a real RSA key,
# and correctly-signed inbox requests built with the same HttpSignature lib
# the verifier is tested against elsewhere (the negative matrix keeps this
# from being circular).
module FederationHelpers
  def create_fed_actor(**attrs)
    n = unique_suffix
    key = OpenSSL::PKey::RSA.new(2048)
    uri = attrs[:uri] || "https://remote#{n}.example/users/alice"
    actor = FedActor.create!({
      uri: uri,
      domain: URI.parse(uri).host,
      actor_type: "Person",
      preferred_username: "alice#{n}",
      inbox_url: "#{uri}/inbox",
      shared_inbox_url: "https://#{URI.parse(uri).host}/inbox",
      public_key_pem: key.public_key.to_pem,
      key_id: "#{uri}#main-key",
      last_fetched_at: Time.current
    }.merge(attrs.except(:uri)))
    [actor, key]
  end

  def signed_inbox_headers(actor, key, body, path: "/inbox", date: Time.now.utc)
    Federation::HttpSignature.sign(
      method: :post, url: "https://app.sola.day#{path}",
      key_id: actor.key_id, private_key: key.to_pem, body: body, date: date
    ).merge("Content-Type" => "application/activity+json")
  end

  def follow_activity(actor, target, id: nil)
    {
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id || "#{actor.uri}#follows/#{SecureRandom.hex(4)}",
      "type" => "Follow",
      "actor" => actor.uri,
      "object" => Federation::Urls.actor_url(target)
    }
  end

  def post_signed_activity(actor, key, activity, path: "/inbox", date: Time.now.utc)
    body = JSON.generate(activity)
    post path, params: body, headers: signed_inbox_headers(actor, key, body, path: path, date: date)
  end
end
