class UserBlueprint < Blueprinter::Base
  identifier :id

  # email is PII and is NOT in the public/default view — it must never leak through
  # member lists, badge owner/creator, participants, etc.
  fields :name, :nickname, :image_url, :created_at

  # Public profile page: bio and public identifiers (wallet, social links).
  view :profile do
    fields :bio, :eth, :social_links
    field :city do |user|
      user.data["city"]
    end
    field :interests do |user|
      user.data["interests"]
    end
    field :introduction do |user|
      user.data["introduction"]
    end
    field :public_links do |user|
      user.data["public_links"]
    end
    field :frequent_space_ids do |user|
      user.data["frequent_space_ids"]
    end
    field :share_activity do |user|
      ActiveModel::Type::Boolean.new.cast(user.data["share_activity"])
    end
    field :visibility do |user|
      user.data["visibility"]
    end
    field :following_count do |user|
      user.follows.active.count
    end
    field :followers_count do |user|
      Follow.active.where(target_type: "User", target_id: user.id).count
    end
  end

  # Private fields, only rendered for the user viewing their own record.
  view :self do
    include_view :profile
    # `admin` is shown so the UI can reveal admin-only actions. Profile update
    # cannot change it; /platform_admins is the only grant (see User).
    # phone is PII on the same footing as email — a CN account may have nothing
    # else identifying it, so the settings screen needs it, and no other view
    # may.
    fields :email, :phone, :permissions, :admin
    field :locale do |user|
      user.data["locale"]
    end
    field :notification_preferences do |user|
      user.data["notification_preferences"]
    end
    field :onboarded do |user|
      ActiveModel::Type::Boolean.new.cast(user.data["onboarded"])
    end
    field :contact do |user|
      { "wechat" => user.data.dig("contact", "wechat") }
    end

    # Whether this account signed in through WeChat, WITHOUT exposing the
    # openid/unionid themselves — those are credentials for the trusted_signin
    # path and have no business in a response. The frontend needs the fact
    # because binding a phone is required for WeChat accounts and only those:
    # a CN WeChat user certainly has a mobile number, an SG email user need not.
    field :wechat do |user|
      user.wechat_openid.present? || user.wechat_unionid.present? || user.wechat_mini_openid.present?
    end
  end

  view :extended do
    association :groups, blueprint: GroupBlueprint
  end
end
