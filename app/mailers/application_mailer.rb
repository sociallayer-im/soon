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
  LOGO_URL = ENV.fetch("MAIL_LOGO_URL", "https://ik.imagekit.io/soladata/g9orl7uo_Xf0S5pGU4").freeze
  # Where mail LINKS point. Canonical frontend host as of 2026-08-15; the old
  # app.sola.day 308s here anyway, so links already sent keep working.
  WEB_URL = ENV.fetch("WEB_URL", "https://sola.day").freeze

  default from: FROM
  layout "mailer"
  helper :mailer
end
