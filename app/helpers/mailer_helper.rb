# Shared building blocks for email templates so each template stays content-only.
module MailerHelper
  BRAND_NAME = ApplicationMailer::BRAND_NAME
  LOGO_URL   = ApplicationMailer::LOGO_URL
  WEB_URL    = ApplicationMailer::WEB_URL

  # A centered call-to-action button. Table-based + inline styles for email-client
  # compatibility (Outlook/Gmail strip <style> blocks and flexbox).
  def cta_button(label, url)
    return if url.blank?

    content_tag(:table, role: "presentation", cellpadding: 0, cellspacing: 0,
      style: "margin: 24px auto;") do
      content_tag(:tr) do
        content_tag(:td, align: "center",
          style: "border-radius: 8px; background: #111827;") do
          link_to(label, url,
            style: "display: inline-block; padding: 12px 28px; color: #ffffff; " \
                   "font-weight: 600; font-size: 15px; text-decoration: none; border-radius: 8px;")
        end
      end
    end
  end
end
