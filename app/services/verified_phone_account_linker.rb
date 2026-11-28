# Both accounts are controlled by this caller: an authenticated email session
# and a code verified by bind_phone. Keep the phone account as the survivor.
class VerifiedPhoneAccountLinker
  class Conflict < StandardError; end

  def self.call(from:, into:)
    User.transaction do
      [from, into].sort_by(&:id).each(&:lock!)
      raise Conflict, "当前账号已绑定手机号，请重新登录后重试" if from.phone.present?
      carry = {}
      %w[email wechat_openid wechat_unionid eth sol].each do |field|
        value = from[field]
        next if value.blank?
        if into[field].present? && into[field] != value
          raise Conflict, "该手机号账号已绑定其他登录身份，请使用原账号登录后处理关联"
        end
        carry[field] = value if into[field].blank?
      end
      %w[name nickname image_url bio].each do |field|
        carry[field] = from[field] if into[field].blank? && from[field].present?
      end
      carry["data"] = from.data.to_h.merge(into.data.to_h)
      carry["social_links"] = from.social_links.to_h.merge(into.social_links.to_h)
      # Never silently discard or transfer platform administration rights.
      raise Conflict, "管理员账号请联系管理员处理关联" if from.permissions.present?
      UserMerger.call(from: from, into: into)
      into.update!(carry)
      GroupInvite.auto_accept_ticket_invites_for(into)
      GroupInvite.auto_accept_phone_invites_for(into)
      into
    end
  end
end
