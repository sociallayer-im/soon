# SURF_SOURCE_DATABASE_URL supplies the Surf source. DATABASE_URL selects Soon.
# bin/rails runner script/import_surf_706.rb [--apply] (defaults to preview)
require "pg"

class Surf706Import
  GROUP = "3mz5yx5l5chbe"
  APP = "3mz5yyvlmotv4"
  APPID = "wxa0fde9108d775630"
  MEMBERS = {
    "3mywwvkpfneca" => ["jiangplus", "3mskfdtf4vn45", "owner"],
    "3mz5sr4dj6odb" => ["strayn", "3n246ievmbath", "member"]
  }.freeze

  def initialize(source)
    @source = source
    @inserted = 0
  end

  def run(apply:)
    @source.exec("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
    ApplicationRecord.transaction do
      group = Group.lock.find_by!(id: GROUP, name: "706-wiconnect", active: true, review_status: "approved")
      MEMBERS.each do |id, (name, target, role)|
        u = one("SELECT name,wechat_openid,wechat_unionid FROM users WHERE id=$1", id)
        user = User.lock.find(target)
        unless u["name"] == name && u["wechat_openid"].present? && u["wechat_unionid"].present? && user.active? && user.wechat_unionid == u["wechat_unionid"]
          raise "Account verification failed for #{name}"
        end
        ensure_record(WechatMiniprogramIdentity, {appid: APPID, openid: u.fetch("wechat_openid")}, {user_id: target, legacy_subject: id})
        row = one("SELECT * FROM memberships WHERE user_id=$1 AND group_id=$2", id, GROUP)
        attrs = Membership.instantiate(row).attributes
        raise "Unexpected membership for #{name}" unless attrs["role"] == role && attrs["active"]
        ensure_record(Membership, {id: attrs.fetch("id")}, attrs.except("id").merge("user_id" => target))
      end
      row = one("SELECT * FROM oauth_applications WHERE id=$1 AND group_id=$2", APP, GROUP)
      attrs = OauthApplication.instantiate(row).attributes
      owner = MEMBERS.keys.first
      callbacks = %w[auth/surf/callback auth/identity-test/callback].map { |path| "https://wiconnect.diaodiao.ink/#{path}" }
      unless attrs["owner_id"] == owner && attrs["name"] == "WiConnect" && attrs["status"] == "active" && attrs["redirect_uris"].sort == callbacks.sort
        raise "Unexpected WiConnect configuration"
      end
      ensure_record(OauthApplication, {id: APP}, attrs.except("id").merge("owner_id" => MEMBERS.fetch(owner)[1], "provider" => "surf"))
      count = Membership.where(group_id: GROUP).count
      group.update_columns(memberships_count: count) if group.reload.memberships_count != count
      puts "#{apply ? 'Apply' : 'Preview'}: #{@inserted} new records"
      raise ActiveRecord::Rollback unless apply
    end
  ensure
    @source.exec("ROLLBACK")
  end

  private

  def one(sql, *params)
    rows = @source.exec_params(sql, params)
    raise "Expected exactly one source record" unless rows.ntuples == 1
    rows.first
  end

  def ensure_record(model, key, attributes)
    record = model.lock.find_or_initialize_by(key)
    if record.new_record?
      record.assign_attributes(attributes)
      record.skip_site_notification = true if record.is_a?(Membership)
      record.save!
      @inserted += 1
    elsif record.is_a?(WechatMiniprogramIdentity) && record.legacy_subject.nil? && record.user_id == attributes.fetch(:user_id)
      record.update!(legacy_subject: attributes.fetch(:legacy_subject))
    elsif attributes.except("created_at", "updated_at").any? { |field, value| record[field] != value }
      raise "Existing #{model.name} conflicts with the source"
    end
  end
end

abort "Usage: bin/rails runner script/import_surf_706.rb [--apply]" unless [[], ["--apply"]].include?(ARGV)
PG.connect(ENV.fetch("SURF_SOURCE_DATABASE_URL")) do |source|
  Surf706Import.new(source).run(apply: ARGV == ["--apply"])
end
