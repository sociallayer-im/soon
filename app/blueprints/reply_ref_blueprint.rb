# The reply a reply points at, embedded for "in reply to @someone".
#
# Deliberately not ReplyBlueprint: that would recurse, and it would send the
# quoted reply's whole body a second time. A flagged or deleted target renders
# as a tombstone instead of its content.
class ReplyRefBlueprint < Blueprinter::Base
  identifier :id

  field :state do |reply|
    reply.flagged? ? "flagged" : "visible"
  end

  field :excerpt do |reply|
    reply.flagged? ? nil : reply.content.to_s.truncate(80)
  end

  association :user, blueprint: UserBlueprint
end
