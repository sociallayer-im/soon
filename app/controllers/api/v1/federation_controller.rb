module Api
  module V1
    # Federation observability + governance for platform admins
    # (design/FEDERATION_PLAN.md §2.9/§2.10). Lives under /api/v1 with normal
    # JWT auth — these are operator endpoints, not protocol surface.
    class FederationController < Api::BaseController
      before_action :require_platform_admin!

      # GET /api/v1/federation/stats
      def stats
        queue = FedDelivery.group(:status).count
        oldest_pending = FedDelivery.where(status: "pending").minimum(:created_at)
        render json: {
          enabled: Federation.enabled?,
          mode: FedDomainPolicy.mode,
          queue: {
            pending: queue["pending"] || 0,
            delivering: queue["delivering"] || 0,
            delivered: queue["delivered"] || 0,
            failed_permanent: queue["failed_permanent"] || 0,
            oldest_pending_age_seconds: oldest_pending && (Time.current - oldest_pending).to_i
          },
          domains: FedDomainStat.order(failed_count: :desc, inbound_rejected_count: :desc)
                                .limit(50).map { |s|
            {domain: s.domain, delivered: s.delivered_count, failed: s.failed_count,
             inbound: s.inbound_count, inbound_rejected: s.inbound_rejected_count,
             unavailable_since: s.unavailable_since, last_error: s.last_error}
          },
          policies: FedDomainPolicy.order(:domain).map { |p|
            {domain: p.domain, policy: p.policy, reason: p.reason}
          }
        }
      end

      # POST /api/v1/federation/policies {domain, policy, reason}
      def create_policy
        policy = FedDomainPolicy.find_or_initialize_by(domain: params[:domain].to_s.downcase)
        policy.assign_attributes(policy: params[:policy], reason: params[:reason],
                                 created_by: current_user.id)
        if policy.save
          # blocking a domain also disables its cached actors' follows/content
          FedActor.where(domain: policy.domain)
                  .update_all(blocked_at: policy.policy == "blocked" ? Time.current : nil)
          render json: {domain: policy.domain, policy: policy.policy}, status: :created
        else
          render_error(policy.errors.full_messages.join(", "))
        end
      end

      # DELETE /api/v1/federation/policies/:domain
      def destroy_policy
        policy = FedDomainPolicy.find_by(domain: params[:domain].to_s.downcase)
        return render_error("no policy for that domain", status: :not_found) if policy.nil?
        FedActor.where(domain: policy.domain).update_all(blocked_at: nil) if policy.policy == "blocked"
        policy.destroy!
        head :no_content
      end

      private

      def require_platform_admin!
        render_error("forbidden", status: :forbidden) unless current_user&.platform_admin?
      end
    end
  end
end
