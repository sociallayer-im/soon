class AddDiscussionToGroups < ActiveRecord::Migration[8.1]
  def change
    # Opt-in on purpose. Defaulting to true would have given every existing
    # group a forum tab it never asked for — the same shape of mistake as
    # admin_notification defaulting to true (design/CHANGELOG.md 2026-08-10).
    add_column :groups, :discussion_enabled, :boolean, null: false, default: false

    # Same three values as can_publish_event / can_join_event / can_view_event,
    # so the settings page can reuse their component.
    add_column :groups, :can_post_topic, :string, default: "member",
      comment: "manager | member | everyone"
  end
end
