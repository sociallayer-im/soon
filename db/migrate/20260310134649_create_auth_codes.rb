class CreateAuthCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :auth_codes, id: :string do |t|
      t.string :recipient, null: false
      t.string :recipient_type, null: false, comment: "email | phone"
      t.string :context, null: false, comment: "signup | login | password_reset | email_verification | phone_verification"
      t.string :code, null: false
      t.datetime :used_at, null: true
      t.datetime :created_at, null: false
    end
  end
end
