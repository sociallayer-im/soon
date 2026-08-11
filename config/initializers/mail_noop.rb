# Lab/staging escape hatch: MAIL_NOOP=true swaps Action Mailer to the :test
# delivery method — the sending code path still runs (templates render,
# deliver_now returns normally) but nothing leaves the machine, so a lab
# without mail credentials doesn't 500 on auth/request_code. Login codes are
# then read out of the auth_codes table by the operator.
#
# Inert unless the variable is exactly "true". Never set it in production:
# it would silently swallow every login code and invite email.
if ENV["MAIL_NOOP"] == "true"
  Rails.application.configure do
    config.action_mailer.delivery_method = :test
  end
end
