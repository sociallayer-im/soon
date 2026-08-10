Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Legacy sails path, kept outside the /api/v1 namespace because that is where
  # the URL already sits in subscribers' calendar apps. See
  # Api::V1::CalendarsController#legacy_group.
  get "group/icalendar", to: "api/v1/calendars#legacy_group"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  namespace :api do
    namespace :v1 do
      # Auth (no JWT required, except bind_email)
      post "auth/request_code",   to: "auth#request_code"
      post "auth/verify_code",    to: "auth#verify_code"
      get  "auth/nonce",          to: "auth#nonce"
      post "auth/verify_wallet",  to: "auth#verify_wallet"
      post "auth/trusted_signin", to: "auth#trusted_signin"
      post "auth/bind_email",     to: "auth#bind_email"
      # Both a session and NEXT_TOKEN — see AuthController#bind_wechat.
      post "auth/bind_wechat",    to: "auth#bind_wechat"

      # Image upload (Cloudflare Images)
      post "upload/image", to: "uploads#image"

      # Public calendar feeds (subscribable in Apple Calendar / Google via webcal).
      # `.ics` suffix optional so subscription URLs can end in .ics.
      get "events/:id/calendar(.ics)", to: "calendars#event", as: :event_calendar
      get "groups/:id/calendar(.ics)", to: "calendars#group", as: :group_calendar

      # Public discovery (homepage + global search)
      get "discover", to: "discover#index"
      get "search",   to: "discover#search"

      # Resources
      resources :users, only: %i[show update] do
        member do
          get :groups
        end
      end

      get "group_invites/pending", to: "group_invites#pending"
      get "group_invites/:id", to: "group_invites#show"

      # Before `resources :groups`, or /groups/directory resolves to #show with
      # id "directory".
      get "groups/directory", to: "groups#directory"

      resources :groups do
        member do
          post :freeze
          post :send_email
        end
        resources :memberships, only: %i[index create update destroy]
        resources :group_invites, only: %i[index create destroy] do
          member do
            post :accept
            post :accept_request
            post :revoke
          end
          collection do
            post :request_invite
            post :send_with_code
            post :accept_with_code
          end
        end
      end

      resources :events do
        collection do
          get :pending_approval
        end
        member do
          post :approve
        end
        resources :participants, only: %i[index create update destroy] do
          member do
            post :approve
            post :reject
          end
          collection do
            post :check_in
          end
        end
        resources :event_roles,  only: %i[index create update destroy]

        get    "form",             to: "forms#get_event_form"
        post   "form",             to: "forms#save_event_form"
        delete "form",             to: "forms#clear_event_form"
        get    "form/submission",  to: "forms#get_submission"
        get    "form/submissions", to: "forms#list_submissions"

        resources :tickets, only: %i[index create]
        patch  "tickets/:ticket_id", to: "tickets#update"
        delete "tickets/:ticket_id", to: "tickets#destroy"
        post "tickets/:ticket_id/rsvp", to: "tickets#rsvp"
      end

      resources :places,   only: %i[index show create] do
        collection do
          get :search
        end
      end
      resources :venues,   only: %i[index show create update destroy] do
        member do
          post :availability, to: "venues#set_availability"
          get :conflict
        end
      end
      resources :tracks,   only: %i[index show create update destroy]
      resources :markers,  only: %i[index show create update destroy]

      # Remember (shared commemorative badge). Static paths before :voucher_id.
      get  "remember/meta",               to: "remember#meta"
      get  "remember/related_groups",     to: "remember#related_groups"
      post "remember",                    to: "remember#create"
      get  "remember/:voucher_id",        to: "remember#show"
      post "remember/:voucher_id/join",   to: "remember#join"
      post "remember/:voucher_id/cancel", to: "remember#cancel"
      post "remember/:voucher_id/mint",   to: "remember#mint"

      post  "recurring",                    to: "recurring#create"
      get   "recurring/:id",                to: "recurring#show"
      patch "recurring/:recurring_id",      to: "recurring#update"
      post  "recurring/:recurring_id/cancel", to: "recurring#cancel"

      resources :badge_classes, only: %i[index show create] do
        collection do
          get :by_user
        end
        member do
          get :invites
        end
      end

      resources :badges, only: %i[index show update] do
        member do
          post :transfer
          post :burn
          post :swap
          post :swap_code
        end
      end

      # Present only when STRIPE_ENABLED (the controller 404s otherwise).
      resources :stripe_settings, only: %i[index create update destroy] do
        collection do
          # The EVENT OWNER's keys (masked), for the ticket-form picker when a
          # co-host/manager edits someone else's event. Read-only — keys are
          # managed exclusively by their owner through the routes above.
          get :for_event
        end
      end

      resources :vouchers, only: %i[index show create] do
        collection do
          post :send_badge
          post :send_badge_by_address
          post :send_badge_by_email
        end
        member do
          get :code, action: :get_code
          post :revoke
          post :use
          post :reject_badge
        end
      end

      post "tickets/verify_payment",         to: "tickets#verify_payment"
      post "tickets/cancel_unpaid_item",      to: "tickets#cancel_unpaid_item"
      post "tickets/set_payment_status",      to: "tickets#set_payment_status"
      post "tickets/checkout_session",        to: "tickets#checkout_session"
      post "tickets/:ticket_item_id/refund",  to: "tickets#refund"
      # Signed per-setting webhook receiver (provisioned by StripeGateway).
      post "webhooks/stripe/:stripe_setting_id", to: "stripe_webhooks#create"
      post "tickets/wechat_prepay",           to: "tickets#wechat_prepay"
      # WeChat Pay callbacks — payment and refund both land here and are told
      # apart by event_type. The URL is what we send as notify_url, so it must
      # stay stable: WeChat retries against it for 24 hours.
      post "webhooks/wechat/:wechat_pay_setting_id", to: "wechat_pay_webhooks#create"
      post "tickets/add_group_ticket_item",   to: "tickets#add_group_ticket_item"
      get  "tickets/list_group_ticket_types", to: "tickets#list_group_ticket_types"
      post "tickets/set_coupon",              to: "tickets#set_coupon"
      get  "tickets/check_coupon",            to: "tickets#check_coupon"
      get  "tickets/get_coupon",              to: "tickets#get_coupon"
      get  "tickets/coupon_price",            to: "tickets#coupon_price"
      get  "tickets/list",                    to: "tickets#list"
      get  "tickets/coupons",                 to: "tickets#coupons"
      get  "tickets/coupon",                  to: "tickets#coupon"
      get  "tickets/coupon_usage",            to: "tickets#coupon_usage"

      resources :activities, only: %i[index] do
        collection do
          post :mark_read
        end
      end

      resources :comments, only: %i[index create] do
        collection do
          post :star
          post :unstar
        end
        member do
          post :remove
        end
      end
    end
  end
end
