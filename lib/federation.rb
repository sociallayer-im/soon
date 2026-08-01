# Federation master switch. Off by default; flipping it on/off is the
# rollout/rollback lever (design/FEDERATION_PLAN.md §6 生产灰度) — routes stay
# drawn, controllers 404 while disabled. Read from ENV on every call so tests
# and a restartless toggle both behave.
module Federation
  def self.enabled?
    ENV["FEDERATION_ENABLED"] == "true"
  end
end
