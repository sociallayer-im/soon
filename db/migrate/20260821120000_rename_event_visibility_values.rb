class RenameEventVisibilityValues < ActiveRecord::Migration[8.1]
  # events.visibility goes from a binary public|private to a 3-value enum:
  #   normal            — default; same list/show behavior public had
  #   open_registration — event opens registration to everyone even when its
  #                       group's can_join_event restricts joining to
  #                       member/manager. New value, nothing backfills into it —
  #                       there is no way to recover which old "public" events
  #                       were meant as an override, so every existing row just
  #                       becomes "normal" (per explicit instruction: don't
  #                       bother trying to split old data by group.can_join_event).
  #   unlisted           — renamed from "private"; same meaning, clearer name.
  def up
    execute "UPDATE events SET visibility = 'normal' WHERE visibility = 'public' OR visibility IS NULL"
    execute "UPDATE events SET visibility = 'unlisted' WHERE visibility = 'private'"
    change_column_default :events, :visibility, from: "public", to: "normal"
    change_column_comment :events, :visibility, from: "public | private", to: "normal | open_registration | unlisted"
  end

  def down
    execute "UPDATE events SET visibility = 'public' WHERE visibility IN ('normal', 'open_registration')"
    execute "UPDATE events SET visibility = 'private' WHERE visibility = 'unlisted'"
    change_column_default :events, :visibility, from: "normal", to: "public"
    change_column_comment :events, :visibility, from: "normal | open_registration | unlisted", to: "public | private"
  end
end
