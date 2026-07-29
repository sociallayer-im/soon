class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_create :set_tsid_primary_key

  # Finds by TSID, falling back to the integer primary key the legacy sails
  # backend used, which the migration preserved in ref_id.
  #
  # Links minted before the cutover are still in circulation — bookmarks,
  # messages, search results, calendar subscriptions — and they carry integers
  # like /event/detail/11399. Without this they 404: an integer can never match
  # a TSID. A digits-only identifier can likewise never BE a TSID, so the
  # fallback is unambiguous and the extra indexed lookup only happens on the
  # legacy path (ref_id carries a partial index on every table that has it).
  #
  # Only for models with a ref_id column: events, badges, badge_classes,
  # vouchers, users, groups. Raises RecordNotFound, like find.
  def self.find_by_id_or_legacy!(identifier)
    record = find_by(id: identifier)
    record ||= find_by(ref_id: identifier.to_s) if identifier.to_s.match?(/\A\d+\z/)
    record || raise(ActiveRecord::RecordNotFound,
                    "Couldn't find #{name} with id or ref_id=#{identifier.inspect}")
  end

  private

  def set_tsid_primary_key
    self.id ||= self.class.generate_tsid
  end

  def self.generate_tsid
    @tsid_generator ||= Tsid::Generator.new
    @tsid_generator.generate
  end
end
