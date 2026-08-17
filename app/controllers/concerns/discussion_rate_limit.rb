# Posting limits for the discussion boards.
#
# This is the product's first surface that anyone with an account can write to,
# and that is readable without one — so it ships with limits rather than
# waiting for the first flood. Shape borrowed from homeland's Topic::RateLimit:
# two cache keys per user, one an interval lock and one an hourly counter.
#
# The numbers are constants, not settings: design/DISCUSSION_PLAN.md 9 rules
# out a settings table, and a limit that can be raised from a web form is a
# limit an attacker with an admin session can raise.
module DiscussionRateLimit
  extend ActiveSupport::Concern

  LIMITS = {
    topic: { interval: 30.seconds, hourly: 10 },
    reply: { interval: 5.seconds,  hourly: 60 }
  }.freeze

  private

  # Returns true when the caller is over a limit, having already rendered the
  # error. Managers are exempt: they are the people who clean up floods, and
  # being rate limited while moderating one is the wrong outcome.
  def rate_limited?(kind, group:)
    return false if GroupPolicy.new(current_user, group).manage?

    limit = LIMITS.fetch(kind)
    lock_key  = "discussion:#{kind}:#{current_user.id}:lock"
    count_key = "discussion:#{kind}:#{current_user.id}:hour"

    if Rails.cache.read(lock_key)
      render_error("posting too quickly, please wait a moment",
                   status: :too_many_requests)
      return true
    end

    if (Rails.cache.read(count_key) || 0) >= limit[:hourly]
      render_error("hourly limit reached (#{limit[:hourly]})",
                   status: :too_many_requests)
      return true
    end

    false
  end

  # Called only after a successful write, so a rejected request does not
  # consume the caller's quota.
  def record_rate_limit(kind)
    limit = LIMITS.fetch(kind)
    Rails.cache.write("discussion:#{kind}:#{current_user.id}:lock", 1,
                      expires_in: limit[:interval])
    count_key = "discussion:#{kind}:#{current_user.id}:hour"
    Rails.cache.write(count_key, (Rails.cache.read(count_key) || 0) + 1,
                      expires_in: 1.hour)
  end
end
