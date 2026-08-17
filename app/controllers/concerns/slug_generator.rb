# Deriving a URL slug from a display name that may not be Latin at all.
#
# `parameterize` strips every non-ASCII character, so "设计组" and "核心团队"
# both reduce to "" and every such name collapses onto the same base — the
# first team gets `team`, the second `team-2`, and the slug stops describing
# anything. (TracksController has the same weakness; its group-name prefix
# hides it rather than fixing it.)
#
# A short random suffix in that case keeps slugs distinct and stable. It is not
# readable, but neither is the alternative, and every one of these is editable
# afterwards by the person who named the thing.
module SlugGenerator
  extend ActiveSupport::Concern

  private

  def generate_slug(name, max: 40, &taken)
    base = name.to_s.parameterize.presence
    base = "#{base}"[0, max] if base
    base ||= SecureRandom.alphanumeric(8).downcase

    slug = base
    n = 1
    slug = "#{base}-#{n += 1}" while taken.call(slug)
    slug
  end
end
