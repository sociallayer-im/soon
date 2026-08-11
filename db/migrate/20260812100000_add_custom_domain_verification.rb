class AddCustomDomainVerification < ActiveRecord::Migration[8.1]
  def change
    # The domain a group is trying to bind, and the token it must publish in
    # DNS to prove it controls it. Separate from custom_domain: an unverified
    # claim must never affect WebFinger, or claiming would be the whole
    # exploit.
    add_column :groups, :custom_domain_pending, :string
    add_column :groups, :custom_domain_token, :string
    add_column :groups, :custom_domain_verified_at, :datetime
  end
end
