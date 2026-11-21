class SodaIdentity < ApplicationRecord
  # This table has a PostgreSQL identity sequence, not a TSID primary key.
  skip_callback :create, :before, :set_tsid_primary_key

  belongs_to :user, inverse_of: :soda_identities

  def self.resolve!(issuer:, subject:, nickname:)
    find_by(issuer: issuer, subject: subject)&.user || transaction(requires_new: true) do
      user = User.new(nickname: nickname)
      user.soda_identities.build(issuer: issuer, subject: subject)
      user.save!
      user
    end
  rescue ActiveRecord::RecordNotUnique
    existing = find_by(issuer: issuer, subject: subject)
    raise unless existing
    existing.user
  end
end
