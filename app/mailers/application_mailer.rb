class ApplicationMailer < ActionMailer::Base
  # Brand configuration lives in exactly one place — the from-address, product
  # name, logo, and web host are read from here by every mailer and by the
  # shared layout. (sails repeated these per-mailer and inlined the logo in
  # every template; centralizing them keeps the individual templates content-only.)
  BRAND_NAME = "Social Layer".freeze
  # NOT app.sola.day -> sola.day, despite the frontend move. The sending domain
  # is a DNS fact, not a branding choice: SPF/DKIM/MX for it are published under
  # send.app.sola.day (see the sola.day Cloudflare zone), and sola.day's own MX
  # points at Google Workspace. Changing this without first verifying a new
  # sending domain in Resend makes every outbound mail fail SPF.
  FROM = ENV.fetch("MAIL_FROM", "Social Layer <send@app.sola.day>").freeze
  INLINE_LOGO_NAME = "sola-logo.png".freeze
  INLINE_LOGO_PATH = Rails.root.join("app/mailers/assets", INLINE_LOGO_NAME).freeze
  # Where mail LINKS point. Canonical frontend host as of 2026-08-15; the old
  # app.sola.day 308s here anyway, so links already sent keep working.
  WEB_URL = ENV.fetch("WEB_URL", "https://sola.day").freeze

  default from: FROM
  layout "mailer"
  helper :mailer
  before_action :attach_inline_logo

  private

  def attach_inline_logo
    attachments.inline[INLINE_LOGO_NAME] = {
      mime_type: "image/png",
      content: File.binread(INLINE_LOGO_PATH)
    }
    @inline_logo_url = attachments[INLINE_LOGO_NAME].url
  end
end
