require "test_helper"

class SodaIdentityTest < ActiveSupport::TestCase
  test "a verified subject gets an independent account and returns to the same account" do
    previous = create_user(nickname: "同名用户")
    identity = { issuer: SodaOauthLogin::ISSUER, subject: "soda-test-1234", nickname: previous.nickname }
    account = SodaIdentity.resolve!(**identity)
    assert_not_equal previous.id, account.id
    assert_equal account.id, SodaIdentity.resolve!(**identity).id
    assert_equal 1, SodaIdentity.where(subject: identity[:subject]).count
    assert account.reload.valid?
  end
end
