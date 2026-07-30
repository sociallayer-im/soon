# A user's own Stripe API keys (design/PAYMENTS_PLAN.md §2.1 / Phase 4).
# Strictly own-rows-only; responses only ever carry the masked tail of a key.
class Api::V1::StripeSettingsController < Api::BaseController
  before_action :require_stripe_enabled!
  before_action :set_setting, only: %i[update destroy]

  # GET /api/v1/stripe_settings — the caller's keys, for settings + pickers
  def index
    render json: StripeSettingBlueprint.render(current_user.stripe_settings.order(:created_at))
  end

  # GET /api/v1/stripe_settings/for_event?event_id=
  #
  # Money always lands in the event owner's account (decision #5), so a
  # co-host/manager editing tickets picks from the OWNER's keys — selectable,
  # never modifiable, and only the masked shape leaves the server. Gated on
  # the same right that lets them edit the ticket at all.
  def for_event
    event = Event.find(params[:event_id])
    authorize event, :update?, policy_class: EventPolicy
    settings = StripeSetting.where(user_id: event.owner_id, status: "active").order(:created_at)
    render json: StripeSettingBlueprint.render(settings)
  end

  # POST /api/v1/stripe_settings  {stripe_setting: {name, secret_key, currency?}}
  def create
    setting = current_user.stripe_settings.new(setting_params)
    validate_and_save(setting, key_changed: true)
  end

  # PATCH /api/v1/stripe_settings/:id — rename, or rotate the key in place
  def update
    @setting.assign_attributes(setting_params)
    key_changed = @setting.will_save_change_to_secret_key?
    # Rotating the key (possibly to a DIFFERENT Stripe account) while orders
    # are in flight would strand them: their sessions become unverifiable,
    # their webhooks unsigned, their refunds unroutable. Same guard as destroy.
    if key_changed && blocking_orders?(@setting)
      return render_error("this key has pending or recently paid orders and cannot be rotated yet")
    end
    StripeGateway.delete_webhook_endpoint(StripeSetting.find(@setting.id)) if key_changed
    validate_and_save(@setting, key_changed: key_changed)
  end

  # DELETE /api/v1/stripe_settings/:id
  # Blocked while non-final orders reference this key: without it we can
  # neither verify pending payments nor refund recent ones (§2.1).
  def destroy
    if blocking_orders?(@setting)
      return render_error("this key has pending or recently paid orders and cannot be removed yet")
    end

    StripeGateway.delete_webhook_endpoint(@setting)
    @setting.destroy
    head :no_content
  end

  private

  def set_setting
    @setting = current_user.stripe_settings.find(params[:id])
  end

  # Shared create/rotate path: prove the key against Stripe's API (capturing
  # the account id), then provision the per-setting webhook endpoint. A
  # webhook failure is not fatal — the setting runs in sweeper-only mode with
  # delayed confirmation (§6.2).
  def validate_and_save(setting, key_changed:)
    was_new = setting.new_record?
    # Cheap local checks (pk_ keys, blank name) before spending a Stripe
    # round-trip — and so the user gets the specific message, not a 401.
    return render_error(setting.errors.full_messages.join(", ")) unless setting.valid?

    if key_changed
      begin
        setting.account_id = StripeGateway.validate_key(setting.secret_key)
        setting.status = "active"
      rescue StripeGateway::InvalidKey => e
        return render_error("Stripe rejected this API key: #{e.message}")
      end
    end

    return render_error(setting.errors.full_messages.join(", ")) unless setting.save

    if key_changed
      endpoint_id, secret = StripeGateway.create_webhook_endpoint(setting)
      setting.update(webhook_endpoint_id: endpoint_id, webhook_secret: secret)
    end
    render json: StripeSettingBlueprint.render(setting), status: was_new ? :created : :ok
  end

  REFUND_WINDOW = 90.days

  def blocking_orders?(setting)
    TicketItem.where(stripe_setting_id: setting.id)
              .where("status = 'pending' OR (status = 'succeeded' AND paid_at > ?)", REFUND_WINDOW.ago)
              .exists?
  end

  def setting_params
    params.require(:stripe_setting).permit(:name, :secret_key, :currency)
  end
end
