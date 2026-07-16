class ApplicationMailer < ActionMailer::Base
  # Brand configuration lives in exactly one place — the from-address, product
  # name, logo, and web host are read from here by every mailer and by the
  # shared layout. (sails repeated these per-mailer and inlined the logo in
  # every template; centralizing them keeps the individual templates content-only.)
  BRAND_NAME = "Social Layer".freeze
  FROM = ENV.fetch("MAIL_FROM", "Social Layer <send@app.sola.day>").freeze
  LOGO_URL = ENV.fetch("MAIL_LOGO_URL", "https://ik.imagekit.io/soladata/g9orl7uo_Xf0S5pGU4").freeze
  WEB_URL = ENV.fetch("WEB_URL", "https://app.sola.day").freeze

  default from: FROM
  layout "mailer"
  helper :mailer
end
