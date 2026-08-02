require "test_helper"

# The canonical host proxies the federation paths to this app, and that proxy
# list lives in another repo (seastar-app/next.config.mjs). A route added here
# but not there resolves on the API host and 404s on the canonical one — which
# is the only host peers ever use. It has happened twice: /comments/:id and
# /actor/outbox. This test states the contract so the next one is caught here
# rather than by a peer failing to dereference something we published.
class FederationRewritesTest < ActionDispatch::IntegrationTest
  # Every root-level federation path a peer can be told to fetch. Keep in step
  # with the `pairs` list in seastar-app/next.config.mjs.
  PROXIED_PATHS = [
    "/.well-known/webfinger",
    "/.well-known/host-meta",
    "/.well-known/nodeinfo",
    "/nodeinfo/2.0",
    "/actor",
    "/actor/outbox",
    "/inbox",
    "/users/:key",
    "/users/:key/inbox",
    "/users/:key/outbox",
    "/users/:key/followers",
    "/users/:key/following",
    "/groups/:key",
    "/groups/:key/inbox",
    "/groups/:key/outbox",
    "/groups/:key/followers",
    "/groups/:key/following",
    "/events/:id",
    "/comments/:id"
  ].freeze

  test "every federation route is in the proxy list" do
    routed = Rails.application.routes.routes.filter_map { |r|
      next unless r.defaults[:controller].to_s.start_with?("federation/")
      r.path.spec.to_s.sub(/\(\.:format\)\z/, "")
        .gsub(%r{:handle|:user_handle|:group_handle}, ":key")
    }.uniq

    missing = routed - PROXIED_PATHS
    assert_empty missing,
                 "these federation routes are not proxied by the canonical host " \
                 "(add them to seastar-app/next.config.mjs and to PROXIED_PATHS): #{missing.inspect}"
  end

  test "the proxy list has no paths this app does not serve" do
    routed = Rails.application.routes.routes.filter_map { |r|
      next unless r.defaults[:controller].to_s.start_with?("federation/")
      r.path.spec.to_s.sub(/\(\.:format\)\z/, "")
        .gsub(%r{:handle|:user_handle|:group_handle}, ":key")
    }.uniq

    stale = PROXIED_PATHS - routed
    assert_empty stale, "the proxy forwards paths nothing serves: #{stale.inspect}"
  end
end
