class WechatMiniprogramIdentity < ApplicationRecord
  skip_callback :create, :before, :set_tsid_primary_key
  belongs_to :user

  # The AppID and both identifiers come from the server-side code exchange.
  def self.resolve!(appid:, openid:, unionid:, profile:)
    transaction do
      mapping = find_by(appid: appid, openid: openid)
      account = mapping&.user
      union_account = User.find_by(wechat_unionid: unionid) if unionid.present?
      if account && union_account && account != union_account
        raise WechatMiniprogramAuth::InvalidCode
      end
      account ||= union_account
      # Old single-app records predate the mapping table. Once an OpenID is
      # attributed to an app, never use it to identify a user in another app.
      legacy = User.find_by(wechat_openid: openid) unless exists?(openid: openid)
      account ||= legacy
      account ||= User.new
      account.lock! if account.persisted?
      if unionid.present? && account.wechat_unionid.present? && account.wechat_unionid != unionid
        raise WechatMiniprogramAuth::InvalidCode
      end
      account.wechat_unionid ||= unionid.presence
      if account.wechat_openid.blank? && !exists?(openid: openid) && (!legacy || legacy == account)
        account.wechat_openid = openid
      end
      profile.each { |key, value| account[key] = value if value.present? && account[key].blank? }
      if account.new_record?
        mapping = account.wechat_miniprogram_identities.build(appid: appid, openid: openid)
      end
      account.save! if account.new_record? || account.changed?
      create!(appid: appid, openid: openid, user: account) unless mapping
      account
    end
  end
end
