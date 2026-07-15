class AddFormIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_reference :events, :form, null: true, foreign_key: true, type: :string
  end
end
