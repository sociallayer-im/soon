# A PEM carried through a single .env line, restored.
#
# The value must be SINGLE-QUOTED in the env file. Unquoted, dotenv treats the
# backslash in \n as an escape character and drops it without inserting
# anything — so every line break arrives as a bare letter "n" and the key is
# quietly garbage. That is checked for by name here, because the model's own
# error ("use apiclient_key.pem, not apiclient_cert.pem") would send whoever
# hits it looking at entirely the wrong thing.
def pem(value, var)
  restored = value.to_s.gsub("\\n", "\n")
  return restored if restored.include?("\n")

  if restored.match?(/-----BEGIN [A-Z ]+-----n/)
    abort "#{var} lost its newlines: they arrived as the letter 'n'.\n" \
          "Single-quote the value in .env.cn.production — unquoted, dotenv eats the backslash:\n" \
          "  #{var}='-----BEGIN …-----\\nMIIE…'"
  end
  abort "#{var} has no line breaks at all — it is not a PEM."
end

namespace :wechat_pay do
  # Installs (or updates) the platform WeChat Pay merchant from the
  # environment. Idempotent — safe to re-run after a credential rotation,
  # which is the intended way to rotate: change the env, run this, done.
  #
  # Deliberately NOT run automatically at boot or from a migration. Boot-time
  # DB writes break asset precompile and run before migrations; a migration
  # reading runtime secrets bakes them into a file that is replayed on every
  # environment. One explicit command, run once per deployment, is the honest
  # shape.
  #
  #   WECHAT_PAY_MCHID=… WECHAT_PAY_APP_ID=… … bin/rails wechat_pay:install
  desc "Create or update the platform WeChat Pay merchant from ENV"
  task install: :environment do
    required = %w[WECHAT_PAY_MCHID WECHAT_PAY_APP_ID WECHAT_PAY_CERT_SERIAL
                  WECHAT_PAY_PRIVATE_KEY WECHAT_PAY_APIV3_KEY]
    missing = required.reject { |k| ENV[k].present? }
    abort "missing: #{missing.join(', ')}" if missing.any?

    setting = WechatPaySetting.find_or_initialize_by(
      mchid: ENV["WECHAT_PAY_MCHID"], sub_mchid: ENV["WECHAT_PAY_SUB_MCHID"].presence
    )
    was_new = setting.new_record?

    setting.assign_attributes(
      user_id: nil, # platform-owned; see WechatPaySetting.platform_default
      name: ENV.fetch("WECHAT_PAY_MERCHANT_NAME", "Platform merchant"),
      app_id: ENV["WECHAT_PAY_APP_ID"],
      cert_serial: ENV["WECHAT_PAY_CERT_SERIAL"],
      private_key: pem(ENV["WECHAT_PAY_PRIVATE_KEY"], "WECHAT_PAY_PRIVATE_KEY"),
      apiv3_key: ENV["WECHAT_PAY_APIV3_KEY"],
      public_key_id: ENV["WECHAT_PAY_PUBLIC_KEY_ID"].presence,
      public_key: ENV["WECHAT_PAY_PUBLIC_KEY"] && pem(ENV["WECHAT_PAY_PUBLIC_KEY"], "WECHAT_PAY_PUBLIC_KEY"),
      status: "active"
    )
    setting.save!

    puts "#{was_new ? 'created' : 'updated'} WeChat Pay merchant #{setting.mchid}" \
         "#{" (sub #{setting.sub_mchid})" if setting.sub_mchid} → #{setting.id}"
    # A callback cannot be verified without the public key, so say so loudly
    # rather than discovering it when the first payment fails to confirm.
    warn "WARNING: no 微信支付公钥 configured — callbacks cannot be verified and will be rejected" if setting.public_key.blank?
  end

  desc "Show the installed WeChat Pay merchant (no secrets)"
  task status: :environment do
    setting = WechatPaySetting.platform_default
    abort "no platform merchant installed — run wechat_pay:install" unless setting

    puts({
      id: setting.id, mchid: setting.mchid, sub_mchid: setting.sub_mchid,
      app_id: setting.app_id, cert_serial: setting.cert_serial,
      public_key_id: setting.public_key_id, has_public_key: setting.public_key.present?,
      status: setting.status, currency: setting.currency
    }.map { |k, v| "#{k}: #{v}" }.join("\n"))
  end
end
