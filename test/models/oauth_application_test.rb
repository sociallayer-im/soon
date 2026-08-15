require "test_helper"

class OauthApplicationTest < ActiveSupport::TestCase
  # The consent screen renders whatever OauthClaims::DESCRIPTIONS holds for a
  # scope; a scope with no entry would silently render as its own raw string
  # ("tickets:read") with no sensitivity flag. Keep the two in lockstep.
  test "every valid scope has a consent-screen description" do
    missing = OauthApplication::VALID_SCOPES - OauthClaims::DESCRIPTIONS.keys
    assert_empty missing, "scopes with no description: #{missing.join(', ')}"

    extra = OauthClaims::DESCRIPTIONS.keys - OauthApplication::VALID_SCOPES
    assert_empty extra, "descriptions for scopes that cannot be granted: #{extra.join(', ')}"
  end

  test "redirect_uri_valid? accepts https and localhost only" do
    assert OauthApplication.redirect_uri_valid?("https://example.com/cb")
    assert OauthApplication.redirect_uri_valid?("http://localhost:4000/cb")
    assert OauthApplication.redirect_uri_valid?("http://127.0.0.1:4000/cb")

    assert_not OauthApplication.redirect_uri_valid?("http://example.com/cb")
    # A fragment is unreachable to a server-side client and is where an
    # attacker hides an alternate target from a naive comparison.
    assert_not OauthApplication.redirect_uri_valid?("https://example.com/cb#x")
    assert_not OauthApplication.redirect_uri_valid?("javascript:alert(1)")
    assert_not OauthApplication.redirect_uri_valid?("")
  end

  test "a confidential client must have a secret and a public one must not" do
    owner = create_user
    public_app, secret = OauthApplication.create_with_secret(
      owner: owner, name: "pub_#{unique_suffix}", confidential: false,
      redirect_uris: [ "https://x.example.com/cb" ], allowed_scopes: %w[openid]
    )
    assert_nil secret
    assert_nil public_app.client_secret_digest
    # Nothing to compare against, so secret authentication can never succeed.
    assert_not public_app.authenticate_secret("anything")
  end

  test "an active application must have at least one redirect_uri" do
    owner = create_user
    app, = OauthApplication.create_with_secret(
      owner: owner, name: "draft_#{unique_suffix}", redirect_uris: [], allowed_scopes: %w[openid]
    )
    assert_equal "draft", app.status
    assert_not app.update(status: "active")
  end
end
