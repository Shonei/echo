defmodule EchoWeb.Router do
  use EchoWeb, :router

  pipeline :browser do
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 8_000_000

    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EchoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 8_000_000

    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :api_auth do
    plug :fetch_session
    plug EchoWeb.Plugs.ExtractToken
    plug EchoWeb.Plugs.ValidateToken
  end

  pipeline :echo do
    # Accept any content type - bypass format checking
    plug EchoWeb.Plugs.AcceptAny
  end

  pipeline :assets do
    # Accept any content type for asset uploads
    plug EchoWeb.Plugs.AcceptAny
  end

  pipeline :asset_upload do
    # Accept any content type for asset uploads
    plug EchoWeb.Plugs.AcceptAny
    # Rate limit: 1 upload per 5 seconds per IP
    plug EchoWeb.Plugs.RateLimit, interval_ms: 5000
  end

  scope "/", EchoWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/chat", ChatWebController, :index
    get "/chat/rooms/new", ChatWebController, :new
    post "/chat/rooms", ChatWebController, :create
    get "/chat/rooms/:id/edit", ChatWebController, :edit
    put "/chat/rooms/:id", ChatWebController, :update
    get "/chat/:room", ChatWebController, :room
  end

  scope "/echo", EchoWeb do
    pipe_through :browser

    get "/request", UIController, :requests
    get "/request/:id", UIController, :request_detail
  end

  scope "/api/v1", EchoWeb do
    pipe_through :api

    post "/login", LoginController, :create

    get "/chat/rooms", ChatController, :index
    get "/chat/:room/messages", ChatController, :messages
    post "/chat/:room/messages", ChatController, :create_message

    get "/rooms", ChatRoomController, :index
    post "/rooms", ChatRoomController, :create
    put "/rooms/:id", ChatRoomController, :update

    scope "/audit" do
      pipe_through EchoWeb.Plugs.AuditAuth
      post "/sessions", AuditController, :create_session
      post "/events", AuditController, :create_event
    end

    scope "/audit" do
      get "/sessions", AuditController, :index
      get "/sessions/:session_id/events", AuditController, :events
    end

    resources "/blogs", BlogController, only: [:index, :show] do
      resources "/revisions", RevisionController, only: [:index]
    end

    scope "/" do
      pipe_through :api_auth
      resources "/blogs", BlogController, only: [:create, :update, :delete]
      put "/blogs/:blog_id/content", BlogController, :update_content
      resources "/blogs/:blog_id/revisions", RevisionController, only: [:create]
    end

    scope "/ai" do
      pipe_through :api_auth
      post "/conversation", AIConversationController, :create
      delete "/conversation/:id", AIConversationController, :delete
      put "/conversation/:id/message", AIConversationController, :message
      put "/conversation/:id/content", AIConversationController, :content
      post "/agents/editor", AIConversationController, :editor
    end

    # List assets endpoint (uses JSON parsing)
    get "/assets", AssetController, :index
  end

  # Assets API - handles binary uploads/downloads with any content type
  scope "/api/v1/assets", EchoWeb do
    pipe_through :assets
    get "/*path", AssetController, :show
  end

  # Asset uploads with rate limiting (1 upload per 5 seconds)
  scope "/api/v1/assets", EchoWeb do
    pipe_through [:asset_upload, :api_auth]
    put "/*path", AssetController, :update
  end

  scope "/api/v1", EchoWeb do
    scope "/echo" do
      pipe_through :echo
      match :*, "/*path", RequestController, :any
    end
  end

  scope "/echo", EchoWeb do
    pipe_through :echo
    match :*, "/*path", RequestController, :any
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:echo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: EchoWeb.Telemetry,
        ecto_repos: [Echo.Repo],
        ecto_sqlite3_extras_options: []
    end
  end
end
