require "test_helper"

# Key lifecycle (design/FEDERATION_TEST_PLAN.md §4.1 KY-1/KY-2/KY-3).
class FederationKeyableTest < ActiveSupport::TestCase
  test "keys are lazily generated, 2048-bit, and stable across calls" do
    user = create_user
    assert_nil user.fed_public_key

    key = user.federation_keypair!
    assert_equal 2048, key.n.num_bits
    assert key.private?

    pub = OpenSSL::PKey::RSA.new(user.fed_public_key)
    refute pub.private?

    # second call returns the same key, no regeneration
    assert_equal key.to_pem, user.federation_keypair!.to_pem
  end

  test "private key is encrypted at rest — raw column holds no PEM" do
    user = create_user
    user.ensure_federation_keys!

    raw = User.connection.select_value(
      User.sanitize_sql(["SELECT fed_private_key FROM users WHERE id = ?", user.id])
    )
    assert raw.present?
    refute_includes raw, "BEGIN RSA PRIVATE KEY"
    refute_includes raw, "BEGIN PRIVATE KEY"
    # but the model decrypts to a parseable key
    assert OpenSSL::PKey::RSA.new(user.reload.fed_private_key).private?
  end

  test "concurrent first access mints exactly one keypair" do
    user = create_user
    pems = []
    2.times.map {
      Thread.new do
        u = User.find(user.id)
        u.ensure_federation_keys!
        pems << u.reload.fed_public_key
      end
    }.each(&:join)
    assert_equal 1, pems.uniq.size
  end

  test "groups get keys too" do
    group = create_group
    assert_equal 2048, group.federation_keypair!.n.num_bits
  end
end
