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
    plug :require_basic_auth
  end

  defp require_basic_auth(conn, _opts) do
    if auth_config = Application.get_env(:echo, :auth) do
      username = Keyword.fetch!(auth_config, :username)
      password = Keyword.fetch!(auth_config, :password)
      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    else
      conn
      |> Plug.Conn.send_resp(:unauthorized, "Authentication not configured")
      |> Plug.Conn.halt()
    end
  end

  pipeline :api do
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 10_000_000

    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :api_auth do
    plug EchoWeb.Plugs.ValidateToken
  end

  # Same gate as the HTML UI. The agent-chat JSON PUT talks to Gemini; it must
  # not be reachable without the browser basic-auth credentials.
  pipeline :basic_auth do
    plug :require_basic_auth
  end

  # Reads that are public but show more to an authenticated caller. Never halts;
  # sets conn.assigns.authenticated? for the controller to branch on.
  pipeline :api_maybe_auth do
    plug EchoWeb.Plugs.MaybeAuthenticate
  end

  pipeline :echo do
    # Accept any content type - bypass format checking
    plug EchoWeb.Plugs.AcceptAny
    plug EchoWeb.Plugs.CacheRawBody
  end

  pipeline :assets do
    # Accept any content type for asset uploads
    plug EchoWeb.Plugs.AcceptAny
  end

  pipeline :asset_upload do
    # Accept any content type for asset uploads
    plug EchoWeb.Plugs.AcceptAny
  end

  pipeline :rate_limit_uploads do
    # Rate limit: 1 upload per 5 seconds per IP. Runs after auth so anonymous
    # callers cannot burn the slot.
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

    get "/assets", AssetUIController, :index
    get "/assets/:id", AssetUIController, :show
    post "/assets", AssetUIController, :create
    delete "/assets/:id", AssetUIController, :delete
    # Workaround for phoenix_html method=delete simulating via POST
    post "/assets/:id", AssetUIController, :delete

    get "/ai-messages", AIMessageController, :index
    get "/ai-messages/:id", AIMessageController, :show

    get "/agent-chat/new", AgentChatController, :new
    post "/agent-chat", AgentChatController, :create
    get "/agent-chat/:id", AgentChatController, :show

    get "/skills", SkillUIController, :index
    get "/skills/:id", SkillUIController, :show
    post "/skills/builder", SkillUIController, :builder
    # Browsers cannot PUT from a form, so these are all POSTs -- the same
    # workaround the asset UI uses for delete.
    post "/skills/:id/variables/:name", SkillUIController, :bind
    post "/skills/:id/tools", SkillUIController, :grant
    post "/skills/:id/run", SkillUIController, :run

    scope "/echo" do
      get "/request", UIController, :requests
      get "/request/:id", UIController, :request_detail
    end
  end

  scope "/api/agent-chat", EchoWeb do
    pipe_through [:api, :basic_auth]

    put "/:id/content", AgentChatController, :content
  end

  scope "/api/v1", EchoWeb do
    pipe_through :api

    post "/login", LoginController, :create

    scope "/" do
      pipe_through :api_maybe_auth
      resources "/blogs", BlogController, only: [:index, :show]
    end

    scope "/" do
      pipe_through :api_auth
      resources "/blogs", BlogController, only: [:create, :update, :delete]
      put "/blogs/:blog_id/content", BlogController, :update_content
      get "/blogs/:blog_id/revisions", RevisionController, :index
      get "/assets", AssetController, :index

      # Skills. `:id` and `:skill_id` both take an id or a slug, so
      # POST /api/v1/skills/weekly-report/run works. Never public: a run spends
      # Gemini money, and instructions are internal config.
      resources "/skills", SkillController, only: [:index, :show, :create, :update, :delete]
      put "/skills/:skill_id/instructions", SkillController, :update_instructions
      post "/skills/:skill_id/run", SkillController, :run

      get "/skills/:skill_id/runs", SkillRunController, :index
      get "/skills/:skill_id/runs/:id", SkillRunController, :show

      get "/skills/:skill_id/variables", SkillVariableController, :index
      put "/skills/:skill_id/variables", SkillVariableController, :define
      put "/skills/:skill_id/variables/:name", SkillVariableController, :bind
    end

    scope "/ai" do
      pipe_through :api_auth
      post "/conversation", AIConversationController, :create
      delete "/conversation/:id", AIConversationController, :delete
      put "/conversation/:id/message", AIConversationController, :message
      put "/conversation/:id/content", AIConversationController, :content
      post "/agents/editor", AIConversationController, :editor
      post "/agents/photographer", AIConversationController, :photographer
      post "/agents/skill_builder", AIConversationController, :skill_builder
    end
  end

  # Assets API - handles binary uploads/downloads with any content type
  scope "/api/v1/assets", EchoWeb do
    pipe_through :assets
    get "/*path", AssetController, :show
  end

  # Asset uploads: auth first, then rate limit (1 upload per 5 seconds)
  scope "/api/v1/assets", EchoWeb do
    pipe_through [:asset_upload, :api_auth, :rate_limit_uploads]
    put "/*path", AssetController, :update
  end

  # Asset deletions
  scope "/api/v1/assets", EchoWeb do
    pipe_through :api_auth
    delete "/*path", AssetController, :delete
  end

  scope "/api/v1", EchoWeb do
    scope "/echo" do
      pipe_through :echo
      match :*, "/*path", RequestController, :any
    end
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
        metrics: EchoWeb.Telemetry
    end
  end
end
