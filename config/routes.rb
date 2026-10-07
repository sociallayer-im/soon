Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Legacy sails path, kept outside the /api/v1 namespace because that is where
  # the URL already sits in subscribers' calendar apps. See
  # Api::V1::CalendarsController#legacy_group.
  get "group/icalendar", to: "api/v1/calendars#legacy_group"

  # OIDC pins these to the root of the issuer origin — a relying party fetches
  # /.well-known/openid-configuration and expects to find everything else from
  # there. They cannot move under /api/v1.
  get ".well-known/openid-configuration", to: "well_known#openid_configuration"
  get ".well-known/jwks.json",            to: "well_known#jwks"
  # The browser entry point a generic OIDC library navigates to; 302s to the
  # consent page in the web app. The JSON authorize endpoints the consent page
  # itself calls are under /api/v1/oauth.
  get "oauth/authorize", to: "well_known#authorize_redirect"

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
      # CN only — both 404 unless PHONE_LOGIN_ENABLED=true.
      post "auth/request_phone_code", to: "auth#request_phone_code"
      post "auth/verify_phone_code",  to: "auth#verify_phone_code"
      post "auth/bind_phone",         to: "auth#bind_phone"
      get  "auth/nonce",          to: "auth#nonce"
      post "auth/verify_wallet",  to: "auth#verify_wallet"
      post "auth/verify_google",  to: "auth#verify_google"
      post "auth/trusted_signin", to: "auth#trusted_signin"
      post "auth/bind_email",     to: "auth#bind_email"
      # Both a session and NEXT_TOKEN — see AuthController#bind_wechat.
      post "auth/bind_wechat",    to: "auth#bind_wechat"

      # OAuth 2.0 / OIDC provider. See design/OAUTH_PROVIDER_PLAN.md.
      # The core endpoints authenticate by client credentials or OAuth bearer
      # token, not by a sola session, so OauthController skips authenticate!.
      get  "oauth/authorize", to: "oauth#authorize_info"
      post "oauth/authorize", to: "oauth#authorize_decision"
      post "oauth/token",     to: "oauth#token"
      # OIDC Core §5.3.1 requires UserInfo to answer on both verbs — a client
      # that sends the token in a form body rather than a header needs POST.
      get  "oauth/userinfo",  to: "oauth#userinfo"
      post "oauth/userinfo",  to: "oauth#userinfo"
      post "oauth/revoke",    to: "oauth#revoke"

      # Developer portal and the user's own consent management (session JWT).
      resources :oauth_applications, path: "oauth/applications" do
        member do
          post :rotate_secret
        end
      end
      resources :oauth_grants, path: "oauth/grants", only: %i[index destroy]

      # Platform admins only — gated on users.admin.
      resources :oauth_admin_applications, path: "oauth/admin/applications", only: %i[index show] do
        member do
          post :review
          post :disable
        end
      end

      # Uploads to the datastore.sola.day bucket (see ObjectStore). "file" is
      # the document rail used by image/file form fields; "image" is unchanged.
      post "upload/image", to: "uploads#image"
      post "upload/file",  to: "uploads#file"

      # Standalone forms — a form with no event behind it. The event-attached
      # form lives at /events/:event_id/form and is a different controller;
      # these two never address the same URL.
      #
      # `forms/submissions` is declared BEFORE the :slug member routes, or it
      # would be swallowed as a form whose slug is "submissions".
      get  "forms/submissions",              to: "standalone_forms#my_submissions"
      get  "forms",                          to: "standalone_forms#index"
      post "forms",                          to: "standalone_forms#create"
      get    "forms/:slug",                  to: "standalone_forms#show"
      patch  "forms/:slug",                  to: "standalone_forms#update"
      delete "forms/:slug",                  to: "standalone_forms#destroy"
      get  "forms/:slug/submissions",        to: "standalone_forms#submissions"
      post "forms/:slug/submissions",        to: "standalone_forms#submit"
      get  "forms/:slug/my_submission",      to: "standalone_forms#my_submission"

      # Public calendar feeds (subscribable in Apple Calendar / Google via webcal).
      # `.ics` suffix optional so subscription URLs can end in .ics.
      get "events/:id/calendar(.ics)", to: "calendars#event", as: :event_calendar
      get "groups/:id/calendar(.ics)", to: "calendars#group", as: :group_calendar

      # Public discovery (homepage + global search)
      get "discover", to: "discover#index"
      get "search",   to: "discover#search"

      # Before `resources :users`, or /users/by_email resolves to #show with
      # id "by_email".
      get "users/by_email", to: "users#by_email"

      # Resources
      resources :users, only: %i[show update] do
        member do
          get :groups
        end
      end
      post "users/merge", to: "users#merge"

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
        get    "form/my_submission", to: "forms#my_submission"
        patch  "form/submission",  to: "forms#update_submission"
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

      # Teams — named subsets of a group's members. Team is to a group's
      # members what Track is to its events: a grouping that is also an
      # identity, and something later features can hang off.
      resources :teams, only: %i[index create update destroy] do
        member do
          get    :members
          post   "members", to: "teams#add_member"
          delete "members/:user_id", to: "teams#remove_member"
        end
      end

      # Discussion boards. Off unless DISCUSSION_ENABLED is set, and off per
      # group unless groups.discussion_enabled — see design/DISCUSSION_PLAN.md.
      # The model is DiscussionCategory-free on purpose: `Category` reads the
      # same from the URL to the SDK, and this is the only categories resource.
      resources :categories, only: %i[index create update destroy]
      resources :topics, only: %i[index show create update destroy] do
        member do
          post :pin
          post :unpin
          post :close
          post :open
          post :flag
          post :unflag
          post :restore
        end
        resources :replies, only: %i[index create], shallow: false
      end
      resources :replies, only: %i[update destroy] do
        member do
          post :flag
          post :unflag
          post :restore
        end
      end

      # Polls. Off unless POLL_ENABLED is set, and off per group unless
      # groups.poll_enabled — see design/POLL_MODULE.md.
      resources :polls, only: %i[index show create update destroy] do
        member do
          post   :vote
          delete :vote, action: :retract
          post   :close
          post   :flag
          post   :unflag
          post   :restore
          get    :export
        end
      end

      # Hackathons. Same two-switch gate as polls (HACKATHON_ENABLED +
      # groups.hackathon_enabled) — see design/HACKATHON_MODULE.md.
      resources :hackathons, only: %i[index show create update destroy] do
        member do
          post  :publish
          post  :unpublish
          patch :tracks
          post  :judges_team
          post  :flag
          post  :unflag
          post  :restore
          get   :export
        end
      end
      resources :hackathon_projects, only: %i[index show create update destroy] do
        member do
          post   :submit
          delete :submit, action: :unsubmit
          post   :review
          post   :award
          post   :star
          delete :star, action: :unstar
          delete :join, action: :leave
          post   :members, action: :add_member
          delete "members/:user_id", action: :remove_member
          post   :transfer
          post   :flag
          post   :unflag
        end
      end

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

      # Present only when WECHAT_PAY_ENABLED (the controller 404s otherwise).
      get "withdrawals/groups",  to: "withdrawals#groups"
      get "withdrawals/balance", to: "withdrawals#balance"
      resources :withdrawals, only: %i[index create]
      # Platform admins only — gated on users.admin. NOT behind
      # WECHAT_PAY_ENABLED: an SG admin should still be able to see/settle
      # historical CN withdrawals if deployments are ever consolidated.
      resources :admin_withdrawals, path: "admin/withdrawals", only: %i[index update]

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
      get  "tickets/order_summary",           to: "tickets#order_summary"
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
