module ContentSafetyGate
  extend ActiveSupport::Concern

  private

  def safe_text_submission?(attrs, scene:)
    text = attrs.to_h.slice("title", "content", "description", "name", "after_signup", "signup_message", "notes", "tags", "requirement_tags").values.compact.join("\n")
    WechatContentSafety.check!(user: current_user, content: text, scene: scene)
    true
  rescue WechatContentSafety::Rejected
    render_error("发布内容含违规信息，请修改后重试。")
    false
  rescue WechatContentSafety::Unavailable
    render_error("内容安全检测暂不可用，请稍后重试。", status: :service_unavailable)
    false
  end
end
