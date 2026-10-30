class OpenGroupDiscussionsByDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :groups, :discussion_enabled, from: false, to: true
    change_column_default :groups, :can_post_topic, from: "member", to: "everyone"
    Group.update_all(discussion_enabled: true, can_post_topic: "everyone")
    Group.find_each(&:ensure_default_discussion_category!)
  end

  def down
    # Restoring defaults must not hide posts or erase administrators' settings.
    change_column_default :groups, :discussion_enabled, from: true, to: false
    change_column_default :groups, :can_post_topic, from: "everyone", to: "member"
  end
end
