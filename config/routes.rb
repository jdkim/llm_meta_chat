Rails.application.routes.draw do
  root "chats#new"

  resources :chats, only: [ :new, :create, :edit, :update, :show ] do
    collection do
      delete :clear
      post :start_new
      get :download_all_csv
    end
    member do
      patch :update_title
      get :download_csv
    end
  end
  resources :prompts, only: [ :show ]

  namespace :api do
    resources :mcp_servers, only: [ :index ], param: :uuid do
      get :tools, on: :member
    end
  end

  # Mount Action Cable
  mount ActionCable.server => "/cable"

  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    sessions: "users/sessions"
  }

  devise_scope :user do
    delete "/logout", to: "users/sessions#destroy", as: :user_logout
    post "/logout", to: "users/sessions#destroy"
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
