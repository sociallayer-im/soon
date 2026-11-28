# The response and all database writes commit together. Transaction-scoped
# advisory locks serialize retries across processes, including a lost response.
module IdempotentCreation
  extend ActiveSupport::Concern
  included { around_action :with_creation_receipt, only: :create }

  private

  def with_creation_receipt
    key = params[:idempotency_key].to_s
    return yield if key.blank? # Older clients remain compatible.
    return render_error("无效的请求标识") unless key.match?(/\A[a-zA-Z0-9_-]{12,100}\z/)
    fingerprint = Digest::SHA256.hexdigest([request.path, request.request_parameters.except("idempotency_key").to_json].join(":"))
    CreationReceipt.transaction do
      lock = Digest::SHA256.hexdigest("#{current_user.id}:#{key}")[0,15].to_i(16)
      CreationReceipt.connection.execute("SELECT pg_advisory_xact_lock(#{lock})")
      receipt = CreationReceipt.find_by(user: current_user, request_key: key)
      if receipt
        return render_error("请求内容已改变，请重新提交", status: :conflict) unless receipt.fingerprint == fingerprint
        self.status = receipt.response_status
        self.content_type = "application/json"
        self.response_body = receipt.response_body
      else
        yield
        if response.status.between?(200,299)
          CreationReceipt.create!(user: current_user, request_key: key, fingerprint: fingerprint,
                                  response_status: response.status, response_body: response.body)
        end
      end
    end
  end
end
