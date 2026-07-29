require "test_helper"

# Cutover safety net: browsers still hold JWTs minted by the legacy sails
# backend when api.sola.day switches to soon. Those tokens carry a different
# payload shape ({"id" => <integer profile id>}, no `exp`) than the ones soon
# mints ({"user_id" => <tsid>}). Api::BaseController#user_from_payload bridges
# the two via users.ref_id. See design/MIGRATION_PLAN.md §3.1.
class Api::LegacyTokenTest < ActionDispatch::IntegrationTest
  # Byte-for-byte what sails' Profile#gen_auth_token produced.
  def legacy_token(profile_id, secret: JwtService::SECRET)
    JWT.encode({
      id: profile_id,
      address_type: "email",
      "https://hasura.io/jwt/claims": {
        "x-hasura-default-role": "user",
        "x-hasura-allowed-roles": [ "user" ],
        "x-hasura-user-id": profile_id.to_s
      }
    }, secret, "HS256")
  end

  def legacy_headers(profile_id, **opts)
    { "Authorization" => "Bearer #{legacy_token(profile_id, **opts)}" }
  end

  test "a sails-issued token authenticates as the migrated user" do
    user = create_user(ref_id: "88123")

    get "/api/v1/users/me", headers: legacy_headers(88123)

    assert_response :success
    assert_equal user.id, json_response["id"]
  end

  test "the legacy id is matched as a string, not coerced against a TSID" do
    # ref_id is a string column; a numeric payload claim must still match.
    user = create_user(ref_id: "7")
    decoy = create_user(ref_id: "70")

    get "/api/v1/users/me", headers: legacy_headers(7)

    assert_response :success
    assert_equal user.id, json_response["id"]
    assert_not_equal decoy.id, json_response["id"]
  end

  test "a legacy token has no exp and stays valid — it must not be rejected" do
    user = create_user(ref_id: "4242")
    payload = JWT.decode(legacy_token(4242), JwtService::SECRET, true, algorithm: "HS256").first

    assert_nil payload["exp"], "sails tokens carried no expiry; the fallback must tolerate that"
    get "/api/v1/users/me", headers: legacy_headers(4242)
    assert_response :success
    assert_equal user.id, json_response["id"]
  end

  test "a legacy id with no migrated user is unauthorized, not a 500" do
    get "/api/v1/users/me", headers: legacy_headers(999_999_999)
    assert_response :unauthorized
  end

  test "a legacy token signed with the wrong secret is rejected" do
    create_user(ref_id: "555")
    get "/api/v1/users/me", headers: legacy_headers(555, secret: "not-the-migration-secret")
    assert_response :unauthorized
  end

  test "users without a ref_id are never reachable by a legacy token" do
    # A user created after the migration has ref_id nil; a token claiming id
    # nil/blank must not fall through to find_by(ref_id: nil) and match them.
    create_user(ref_id: nil)
    token = JWT.encode({ id: nil }, JwtService::SECRET, "HS256")

    get "/api/v1/users/me", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :unauthorized
  end

  test "soon-issued tokens still work — the fallback is additive" do
    user = create_user
    get "/api/v1/users/me", headers: auth_headers(user)
    assert_response :success
    assert_equal user.id, json_response["id"]
  end

  test "user_id wins over a stray id claim" do
    modern = create_user
    legacy = create_user(ref_id: "31337")
    token = JWT.encode({ "user_id" => modern.id, "id" => 31337 }, JwtService::SECRET, "HS256")

    get "/api/v1/users/me", headers: { "Authorization" => "Bearer #{token}" }

    assert_response :success
    assert_equal modern.id, json_response["id"]
    assert_not_equal legacy.id, json_response["id"]
  end

  test "optional auth accepts a legacy token on a public endpoint" do
    user = create_user(ref_id: "60001")
    group = create_group(owner: user)
    event = create_event(group: group, owner: user)

    get "/api/v1/events/#{event.id}", headers: legacy_headers(60001)

    assert_response :success
  end

  test "optional auth stays anonymous on a legacy token with no matching user" do
    user = create_user
    group = create_group(owner: user)
    create_event(group: group, owner: user)

    # An unmatched legacy token must degrade to anonymous, not 401 the request —
    # identical to sending no Authorization header at all.
    get "/api/v1/events", headers: legacy_headers(999_999_998)
    assert_response :success
    with_token = response.body

    get "/api/v1/events"
    assert_response :success
    assert_equal response.body, with_token
  end
end
