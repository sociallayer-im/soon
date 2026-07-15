class CreateFormSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :form_submissions, id: :string do |t|
      t.references :form, null: false, foreign_key: true, type: :string
      t.references :user, null: false, foreign_key: true, type: :string
      t.string :status, default: "pending", null: false
      t.boolean :starred, default: false, null: false
      t.text :admin_note
      t.datetime :submitted_at, default: -> { "CURRENT_TIMESTAMP" }, null: false

      t.timestamps
    end
    add_index :form_submissions, [:form_id, :status]
    add_index :form_submissions, [:form_id, :user_id], unique: true
  end
end
