class AddBookingWindowToVenues < ActiveRecord::Migration[8.1]
  # Restores the overall availability date range sails/ had (venue.rb:22,38,44-53)
  # but soon/'s schema dropped — a venue meant only for a fixed popup-city date
  # range could otherwise be booked outside it with no rejection.
  def change
    add_column :venues, :start_date, :date
    add_column :venues, :end_date, :date
  end
end
