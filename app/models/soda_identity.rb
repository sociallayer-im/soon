class SodaIdentity < ApplicationRecord
  belongs_to :user, inverse_of: :soda_identities

  def self.resolve!(issuer:, subject:, nickname:)
    find_by(issuer: issuer, subject: subject)&.user || transaction(requires_new: true) do
      user = User.new(nickname: nickname)
      user.soda_identities.build(issuer: issuer, subject: subject)
      user.save!
      user
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(issuer: issuer, subject: subject).user
  end
end
