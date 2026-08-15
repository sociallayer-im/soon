require "test_helper"

# Every OAuth table carries a live FK to users (and one to groups). Without a
# `dependent:` on the other side, deleting either row raises
# ActiveRecord::InvalidForeignKey — which would take out user merges and group
# deletion, two paths that have nothing to do with OAuth.
class OauthCascadeTest < ActiveSupport::TestCase
  test "merging a user who authorized an app does not hit a foreign key" do
    from = create_user
    into = create_user
    client, = create_oauth_application
    OauthGrant.upsert_for(user: from, application: client, scopes: %w[openid])
    access = OauthAccessToken.issue(user: from, application: client, scopes: %w[openid])
    OauthRefreshToken.issue(user: from, application: client, access_token: access)

    assert_nothing_raised { UserMerger.call(from: from, into: into) }
    assert_nil User.find_by(id: from.id)
    # The consent dies with the account — a merge must not hand a third party
    # access to the surviving one.
    assert_equal 0, OauthGrant.where(user_id: into.id, application_id: client.id).count
    assert_nil OauthAccessToken.find_by(id: access.id)
  end

  test "a merged developer keeps the applications they own" do
    from = create_user
    into = create_user
    client, = create_oauth_application(owner: from)

    UserMerger.call(from: from, into: into)
    assert_equal into.id, client.reload.owner_id
  end

  test "deleting a group nullifies its applications rather than blocking" do
    owner = create_user
    group = create_group(owner: owner)
    client, = create_oauth_application(owner: owner, group_id: group.id)

    assert_nothing_raised { group.destroy! }
    assert_nil client.reload.group_id
    assert_equal owner.id, client.owner_id
  end

  test "deleting a user destroys the applications they own" do
    owner = create_user
    client, = create_oauth_application(owner: owner)

    assert_nothing_raised { owner.destroy! }
    assert_nil OauthApplication.find_by(id: client.id)
  end
end
