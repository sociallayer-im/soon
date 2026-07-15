Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  namespace :api do
    namespace :v1 do
      # Auth (no JWT required)
      post "auth/request_code", to: "auth#request_code"
      post "auth/verify_code",  to: "auth#verify_code"

      # Resources
      resources :users, only: %i[show update]

      get "group_invites/pending", to: "group_invites#pending"

      resources :groups do
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
        resources :participants, only: %i[index create update destroy] do
          member do
            post :approve
          end
        end
        resources :event_roles,  only: %i[index create update destroy]

        get    "form",             to: "forms#get_event_form"
        post   "form",             to: "forms#save_event_form"
        delete "form",             to: "forms#clear_event_form"
        get    "form/submission",  to: "forms#get_submission"
        get    "form/submissions", to: "forms#list_submissions"

        resources :tickets, only: %i[index create]
        post "tickets/:ticket_id/rsvp", to: "tickets#rsvp"
      end

      resources :places,   only: %i[index show]
      resources :venues,   only: %i[index show]
      resources :tracks,   only: %i[index show]
      resources :markers,  only: %i[index show create update destroy]

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
      post "tickets/stripe_callback",         to: "tickets#stripe_callback"
      post "tickets/stripe_client_secret",    to: "tickets#stripe_client_secret"
      get  "tickets/stripe_config",           to: "tickets#stripe_config"
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
