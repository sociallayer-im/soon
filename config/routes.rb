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

      resources :groups do
        resources :memberships, only: %i[index create update destroy]
      end

      resources :events do
        resources :participants, only: %i[index create update destroy]
        resources :event_roles,  only: %i[index create update destroy]
      end

      resources :places,   only: %i[index show]
      resources :venues,   only: %i[index show]
      resources :tracks,   only: %i[index show]
      resources :markers,  only: %i[index show create update destroy]
    end
  end
end
