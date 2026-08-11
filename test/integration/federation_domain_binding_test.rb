require "test_helper"

# Custom-domain binding (PLAN §9.4) and the alias/move surfaces the group
# settings and profile pages drive.
class FederationDomainBindingTest < ActionDispatch::IntegrationTest
  include FederationHelpers

  SVC = Federation::DomainBindingService

  setup do
    ENV["FEDERATION_ENABLED"] = "true"
    @owner = create_user(name: "do#{unique_suffix}")
    @group = create_group(name: "dg#{unique_suffix}", owner: @owner)
    @headers = auth_headers(@owner)
    @outsider = create_user(name: "dx#{unique_suffix}")
  end

  teardown { ENV.delete("FEDERATION_ENABLED") }

  def auth_headers(user)
    {"Authorization" => "Bearer #{JwtService.encode({user_id: user.id})}"}
  end

  def stub_txt(map, &block)
    SVC.stub(:txt_records, ->(name) { map[name] || [] }, &block)
  end

  def claim!(domain = "hi.example.org")
    post "/api/v1/federation/groups/#{@group.id}/domain",
         params: {domain: domain}.to_json,
         headers: @headers.merge("Content-Type" => "application/json")
    JSON.parse(response.body)
  end

  # --- claim -------------------------------------------------------------------

  test "claiming a domain returns a TXT challenge and does not bind anything yet" do
    body = claim!
    assert_response :created
    assert_equal "pending", body["state"]
    assert_equal "hi.example.org", body["pending_domain"]
    assert_equal "_sola-challenge.hi.example.org", body.dig("dns_challenge", "name")
    assert_match(/\Asola-domain-verification=\w{32}\z/, body.dig("dns_challenge", "value"))
    assert_nil @group.reload.custom_domain,
               "an unverified claim must not reach WebFinger — claiming would be the whole exploit"
  end

  test "re-claiming the same domain keeps the token so the DNS record stays valid" do
    first = claim!
    second = claim!
    assert_equal first.dig("dns_challenge", "value"), second.dig("dns_challenge", "value")
  end

  test "claiming a different domain mints a fresh token" do
    first = claim!("hi.example.org")
    second = claim!("other.example.org")
    refute_equal first.dig("dns_challenge", "value"), second.dig("dns_challenge", "value")
  end

  test "a malformed domain is rejected" do
    ["not a host", "localhost", "example", "", "-bad.example.org", "x..example.org"].each do |bad|
      claim!(bad)
      assert_response :unprocessable_entity, "expected #{bad.inspect} to be rejected"
    end
  end

  test "a URL is normalized down to its hostname" do
    body = claim!("HTTPS://Hi.Example.ORG/settings")
    assert_response :created
    assert_equal "hi.example.org", body["pending_domain"]
  end

  test "the instance's own host cannot be claimed" do
    claim!(Federation::Urls.host)
    assert_response :unprocessable_entity
    assert_match(/own host/, JSON.parse(response.body)["error"],
                 "binding the canonical host would hijack every actor on the instance")
  end

  test "a domain already bound to another group cannot be claimed" do
    other = create_group(name: "dg#{unique_suffix}", owner: @owner)
    other.update!(custom_domain: "taken.example.org")
    claim!("taken.example.org")
    assert_response :unprocessable_entity
  end

  test "a non-manager cannot claim, verify, or read the domain" do
    headers = auth_headers(@outsider)
    post "/api/v1/federation/groups/#{@group.id}/domain",
         params: {domain: "hi.example.org"}.to_json,
         headers: headers.merge("Content-Type" => "application/json")
    assert_response :forbidden
    get "/api/v1/federation/groups/#{@group.id}/domain", headers: headers
    assert_response :forbidden
  end

  # --- verify ------------------------------------------------------------------

  test "verification binds the domain only when the TXT record matches" do
    body = claim!
    challenge = body.dig("dns_challenge", "value")

    stub_txt("_sola-challenge.hi.example.org" => ["sola-domain-verification=wrongvalue"]) do
      post "/api/v1/federation/groups/#{@group.id}/domain/verify", headers: @headers
    end
    assert_response :unprocessable_entity
    assert_nil @group.reload.custom_domain

    stub_txt("_sola-challenge.hi.example.org" => ["unrelated=1", challenge]) do
      post "/api/v1/federation/groups/#{@group.id}/domain/verify", headers: @headers
    end
    assert_response :success
    @group.reload
    assert_equal "hi.example.org", @group.custom_domain
    assert_not_nil @group.custom_domain_verified_at
    assert_nil @group.custom_domain_token, "the spent challenge must not linger"
  end

  test "a bound domain moves the group's acct without moving its actor id" do
    body = claim!
    stub_txt("_sola-challenge.hi.example.org" => [body.dig("dns_challenge", "value")]) do
      post "/api/v1/federation/groups/#{@group.id}/domain/verify", headers: @headers
    end
    @group.reload
    assert_equal "#{@group.name}@hi.example.org", Federation::Urls.acct(@group)
    assert_equal "#{Federation::Urls.base_url}/groups/#{@group.id}", Federation::Urls.actor_url(@group),
                 "the actor id is immutable; the domain is a signature, not an identity"

    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@hi.example.org"}
    assert_response :success
    assert_equal Federation::Urls.actor_url(@group),
                 JSON.parse(response.body)["links"].find { |l| l["rel"] == "self" }["href"]
  end

  test "verifying without a claim is an error, not a crash" do
    post "/api/v1/federation/groups/#{@group.id}/domain/verify", headers: @headers
    assert_response :unprocessable_entity
  end

  test "a domain bound to another group between claim and verify does not bind twice" do
    body = claim!
    create_group(name: "dg#{unique_suffix}", owner: @owner).update!(custom_domain: "hi.example.org")
    stub_txt("_sola-challenge.hi.example.org" => [body.dig("dns_challenge", "value")]) do
      post "/api/v1/federation/groups/#{@group.id}/domain/verify", headers: @headers
    end
    assert_response :unprocessable_entity
    assert_nil @group.reload.custom_domain
  end

  # --- unbind ------------------------------------------------------------------

  test "unbinding restores the canonical acct and clears the claim" do
    @group.update!(custom_domain: "hi.example.org", custom_domain_verified_at: Time.current)
    delete "/api/v1/federation/groups/#{@group.id}/domain", headers: @headers
    assert_response :success
    @group.reload
    assert_nil @group.custom_domain
    assert_equal "#{@group.name}@#{Federation::Urls.host}", Federation::Urls.acct(@group)

    get "/.well-known/webfinger", params: {resource: "acct:#{@group.name}@hi.example.org"}
    assert_response :not_found, "an unbound domain must stop resolving"
  end

  # --- aliases -----------------------------------------------------------------

  test "group aliases can be listed, added and removed by a manager" do
    uri = "https://other.example/groups/9"
    post "/api/v1/federation/groups/#{@group.id}/aliases", params: {uri: uri}.to_json,
         headers: @headers.merge("Content-Type" => "application/json")
    assert_response :created
    assert_equal [uri], JSON.parse(response.body)["also_known_as"]

    get "/api/v1/federation/groups/#{@group.id}/aliases", headers: @headers
    assert_equal [uri], JSON.parse(response.body)["also_known_as"]

    delete "/api/v1/federation/groups/#{@group.id}/aliases", params: {uri: uri}, headers: @headers
    assert_empty JSON.parse(response.body)["also_known_as"]
  end

  test "an actor cannot alias its own id" do
    post "/api/v1/federation/groups/#{@group.id}/aliases",
         params: {uri: Federation::Urls.actor_url(@group)}.to_json,
         headers: @headers.merge("Content-Type" => "application/json")
    assert_response :unprocessable_entity,
                    "self-aliasing would make a self-Move look attested"
  end

  test "the signed-in user manages their own aliases" do
    uri = "https://mas.example/ap/users/7"
    post "/api/v1/federation/profile/aliases", params: {uri: uri}.to_json,
         headers: @headers.merge("Content-Type" => "application/json")
    assert_response :created
    assert_equal [uri], @owner.reload.fed_also_known_as

    get "/api/v1/federation/profile/aliases", headers: auth_headers(@outsider)
    assert_empty JSON.parse(response.body)["also_known_as"],
                 "one user's aliases must not leak into another's"

    delete "/api/v1/federation/profile/aliases", params: {uri: uri}, headers: @headers
    assert_empty @owner.reload.fed_also_known_as
  end

  test "profile aliases require a token" do
    get "/api/v1/federation/profile/aliases"
    assert_response :unauthorized
  end

  # --- move --------------------------------------------------------------------

  test "the move endpoint reports the attestation failure the UI has to show" do
    remote, = create_fed_actor
    post "/api/v1/federation/groups/#{@group.id}/move", params: {target: remote.uri}.to_json,
         headers: @headers.merge("Content-Type" => "application/json")
    assert_response :unprocessable_entity
    assert_nil @group.reload.fed_moved_to
  end
end
