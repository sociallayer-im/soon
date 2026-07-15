class CreateFormFields < ActiveRecord::Migration[8.1]
  def change
    create_table :form_fields, id: :string do |t|
      t.references :form, null: false, foreign_key: true, type: :string
      t.string :label, null: false
      t.string :field_type, null: false
      t.boolean :required, default: false, null: false
      t.boolean :for_admin, default: false
      t.integer :position, default: 0, null: false
      t.jsonb :options, default: []

      t.timestamps
    end
    add_index :form_fields, [:form_id, :position]
  end
end
