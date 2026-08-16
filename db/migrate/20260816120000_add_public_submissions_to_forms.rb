class AddPublicSubmissionsToForms < ActiveRecord::Migration[8.1]
  # Opt-in, so every form that already exists keeps its responses private —
  # the one default that cannot surprise anybody. Backfilling `true` here
  # would publish answers people gave a private form, and mail cannot be
  # unsent applies just as much to a page that was already crawled.
  def change
    add_column :forms, :public_submissions, :boolean, null: false, default: false
  end
end
