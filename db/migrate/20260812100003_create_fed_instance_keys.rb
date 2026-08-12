class CreateFedInstanceKeys < ActiveRecord::Migration[8.1]
  # Singleton keypair for the instance actor (/actor) — it signs outbound
  # GETs for authorized-fetch peers (Mastodon's Account.representative
  # equivalent). One row, lazily created.
  def change
    create_table :fed_instance_keys, id: :string do |t|
      t.text :private_key, null: false
      t.text :public_key, null: false
      t.timestamps
    end
  end
end
