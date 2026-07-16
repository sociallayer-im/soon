# Resend is the ActionMailer delivery backend (wired via
# `config.action_mailer.delivery_method = :resend` in the production env). The
# `:resend` delivery method is registered by the resend gem's railtie and reads
# this api key at send time. Guard on presence so development/test environments
# without a key still boot cleanly.
Resend.api_key = ENV["RESEND_API_KEY"] if ENV["RESEND_API_KEY"].present?
