class OpenGroupDiscussionsByDefault < ActiveRecord::Migration[8.1]
  # Historical Surf rollout. Replaying it against an existing Soon database
  # must preserve each administrator's posting policy and existing boards.
  def change
  end
end
