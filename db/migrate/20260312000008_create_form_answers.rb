class CreateFormAnswers < ActiveRecord::Migration[8.1]
  def change
    create_table :form_answers, id: :string do |t|
      t.references :form_submission, null: false, foreign_key: true, type: :string
      t.references :form_field, null: false, foreign_key: true, type: :string
      t.text :value

      t.timestamps
    end
  end
end
