require "test_helper"

class Federation::UrlsTest < ActiveSupport::TestCase
  URLS = Federation::Urls

  test "host defaults from WEB_URL and FEDERATION_HOST overrides it" do
    assert_equal "app.sola.day", URLS.host
    ENV["FEDERATION_HOST"] = "fed.example"
    assert_equal "fed.example", URLS.host
    assert_equal "https://fed.example", URLS.base_url
  ensure
    ENV.delete("FEDERATION_HOST")
  end

  test "actor urls by type, key id fragment stable" do
    user = create_user
    group = create_group
    assert_equal "https://app.sola.day/users/#{user.name}", URLS.actor_url(user)
    assert_equal "https://app.sola.day/groups/#{group.name}", URLS.actor_url(group)
    assert_equal "#{URLS.actor_url(user)}#main-key", URLS.key_id(user)
    assert_equal "#{URLS.actor_url(user)}/inbox", URLS.inbox_url(user)
    assert_equal "https://app.sola.day/inbox", URLS.shared_inbox_url
    assert_equal "https://app.sola.day/actor", URLS.instance_actor_url
  end

  test "non-actor raises" do
    assert_raises(ArgumentError) { URLS.actor_url(Object.new) }
  end

  test "event object url is distinct from the html url" do
    event = Struct.new(:id).new("ABC123")
    assert_equal "https://app.sola.day/events/ABC123", URLS.event_url(event)
    assert_equal "https://app.sola.day/event/detail/ABC123", URLS.event_html_url(event)
  end

  test "local? matches host only" do
    assert URLS.local?("https://app.sola.day/users/foo")
    refute URLS.local?("https://evil.example/users/foo")
    refute URLS.local?("not a uri")
  end
end
