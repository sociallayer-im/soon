class UserBlueprint < Blueprinter::Base
  identifier :id

  # email is PII and is NOT in the public/default view — it must never leak through
  # member lists, badge owner/creator, participants, etc.
  fields :name, :nickname, :image_url, :created_at

  # Public profile page: bio and public identifiers (wallet, social links).
  view :profile do
    fields :bio, :eth, :social_links
  end

  # Private fields, only rendered for the user viewing their own record.
  view :self do
    include_view :profile
    # `admin` is read-only everywhere above the database — it is here so the UI
    # can show admin-only affordances, not so it can be changed (see User).
    # phone is PII on the same footing as email — a CN account may have nothing
    # else identifying it, so the settings screen needs it, and no other view
    # may.
    fields :email, :phone, :permissions, :admin

    # Whether this account signed in through WeChat, WITHOUT exposing the
    # openid/unionid themselves — those are credentials for the trusted_signin
    # path and have no business in a response. The frontend needs the fact
    # because binding a phone is required for WeChat accounts and only those:
    # a CN WeChat user certainly has a mobile number, an SG email user need not.
    field :wechat do |user|
      user.wechat_openid.present? || user.wechat_unionid.present?
    end
  end

  view :extended do
    association :groups, blueprint: GroupBlueprint
  end
end
