# Per-merchant WeChat Pay callback receiver, the counterpart of
# StripeWebhooksController: verify → decrypt → persist (notification id as PK
# = idempotency) → enqueue → answer fast. Payment and refund notifications
# both arrive here and are told apart by event_type.
#
# Speed is part of the contract, not a nicety: WeChat treats any response
# slower than 5 seconds as a failure and retries up to 15 times across 24
# hours. Nothing may happen inline that could block.
class Api::V1::WechatPayWebhooksController < Api::BaseController
  skip_before_action :authenticate!
  before_action :require_wechat_pay_enabled!

  def create
    setting = WechatPaySetting.find_by(id: params[:wechat_pay_setting_id])
    return fail_callback(:not_found, "unknown merchant") unless setting

    body = request.raw_post
    unless verified?(setting, body)
      # Deliberately no detail: an unverified caller learns nothing about why.
      return fail_callback(:unauthorized, "signature verification failed")
    end

    envelope = JSON.parse(body)
    return fail_callback(:bad_request, "missing notification id") if envelope["id"].blank?

    resource = WechatPayGateway.decrypt_resource(setting, envelope["resource"] || {})
    # A verified envelope we cannot decrypt means the APIv3 key is wrong. Answer
    # FAIL so WeChat keeps retrying — the notification is real and will become
    # processable once the key is fixed, which a 200 would throw away.
    return fail_callback(:bad_request, "could not decrypt resource") unless resource

    WechatPayEvent.create!(
      id: envelope["id"], wechat_pay_setting_id: setting.id,
      event_type: envelope["event_type"].to_s,
      # The decrypted contents replace the ciphertext: the job has no key, and
      # keeping both would store the same data twice, once unreadably.
      payload: envelope.merge("resource" => resource)
    )
    WechatPayWebhookJob.perform_later(envelope["id"])
    head :no_content
  rescue ActiveRecord::RecordNotUnique
    # Already stored — the retry has done its job. Acknowledge so it stops.
    head :no_content
  rescue JSON::ParserError
    fail_callback(:bad_request, "malformed body")
  end

  private

  def verified?(setting, body)
    WechatPayGateway.verify_notification(
      setting,
      timestamp: request.headers["Wechatpay-Timestamp"],
      nonce: request.headers["Wechatpay-Nonce"],
      body: body,
      signature: request.headers["Wechatpay-Signature"],
      serial: request.headers["Wechatpay-Serial"]
    )
  end

  # WeChat reads failure from the status code plus this exact body shape.
  def fail_callback(status, message)
    render json: { code: "FAIL", message: message }, status: status
  end
end
