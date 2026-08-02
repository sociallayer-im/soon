module Federation
  # Delivers exactly one fed_deliveries row: sign, POST, record the outcome.
  # The AR connection is released for the duration of the HTTP call — with a
  # 6-connection pool and one background thread, holding it through a 10s
  # remote timeout would starve the app (design/FEDERATION_PLAN.md §2.6).
  class DeliveryJob < ApplicationJob
    queue_as :federation

    def perform(delivery_id)
      delivery = FedDelivery.find_by(id: delivery_id)
      return if delivery.nil? || delivery.status != "delivering"

      domain_gate = URI.parse(delivery.inbox_url).host.to_s.downcase
      # Re-check the gates at send time, not just at enqueue: an admin block
      # or the kill switch flipping mid-flight must stop a claimed delivery.
      unless Federation.enabled?
        # not terminal — re-enabling the switch resumes where we stopped
        delivery.update!(status: "pending", next_attempt_at: 10.minutes.from_now,
                         last_error: "federation disabled")
        return
      end
      unless FedDomainPolicy.domain_allowed?(domain_gate)
        delivery.update!(status: "suppressed", last_error: "domain blocked by policy")
        Logging.log(:out, delivery.payload["type"], domain: domain_gate, status: "suppressed")
        return
      end

      body = JSON.generate(delivery.payload)
      headers = HttpSignature.sign(
        method: :post, url: delivery.inbox_url,
        key_id: sender_key_id(delivery), private_key: sender_private_key(delivery),
        body: body
      )
      headers["Content-Type"] = "application/activity+json"

      domain = URI.parse(delivery.inbox_url).host.to_s.downcase
      status, error, retry_after = perform_request(delivery.inbox_url, body, headers)

      delivery.increment!(:attempts)
      delivery.mark_result!(status, error: error, retry_after: retry_after)
      FedDomainStat.record_delivery!(domain, success: delivery.status == "delivered", error: error)
      Logging.log(:out, delivery.payload["type"], domain: domain, status: delivery.status,
                  http: status, attempts: delivery.attempts, ms: nil)
    end

    private

    def perform_request(url, body, headers)
      # hand the connection back for the duration of the remote call; AR
      # lazily re-checks out on the next query
      ActiveRecord::Base.connection_pool.release_connection
      response = HttpClient.post(url, body: body, headers: headers)
      [response.status, nil, response.headers["retry-after"]]
    rescue HttpClient::Error => e
      [nil, e.message, nil]
    end

    # Prefer the key snapshotted at enqueue time: the sender row may be gone
    # by now (a deleted group's own Delete announcement) or its key rotated —
    # the signature must match the identity the payload claims.
    def sender_key_id(delivery)
      return delivery.signing_key_id if delivery.signing_key_id.present?
      sender = sender_for(delivery)
      sender ? Urls.key_id(sender) : Urls.instance_key_id
    end

    def sender_private_key(delivery)
      return delivery.signing_key_pem if delivery.signing_key_pem.present?
      sender = sender_for(delivery)
      sender ? sender.federation_keypair!.to_pem : FedInstanceKey.current.private_key
    end

    def sender_for(delivery)
      return nil if delivery.sender_type == "instance"
      delivery.sender_type.constantize.find_by(id: delivery.sender_id)
    end
  end
end
