class AddImageNoteToEvents < ActiveRecord::Migration[8.1]
  def change
    # An image shown only to confirmed attendees (group QR codes, mostly).
    # Access is gated in the blueprint, not here — the column is just a URL.
    add_column :events, :image_note, :string
  end
end
