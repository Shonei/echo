defmodule EchoWeb.Router do
  use EchoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EchoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :echo do
    # Accept any content type - bypass format checking
    plug EchoWeb.Plugs.AcceptAny
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

    # User management web interface
    resources "/users", UserWebController do
      get "/type/:type", UserWebController, :by_type, as: :user_by_type
      post "/tools", UserWebController, :add_tool, as: :user_tool
      delete "/tools/:tool_id", UserWebController, :delete_tool, as: :user_tool
    end

    get "/users/type/:type", UserWebController, :by_type
  end

  scope "/echo", EchoWeb do
    pipe_through :browser

    get "/request", UIController, :requests
    get "/request/:id", UIController, :request_detail
  end

  scope "/api/v1", EchoWeb do
    pipe_through :api

    get "/chat/rooms", ChatController, :index
    get "/chat/:room/messages", ChatController, :messages
    post "/chat/:room/messages", ChatController, :create_message

    get "/rooms", ChatRoomController, :index
    post "/rooms", ChatRoomController, :create
    put "/rooms/:id", ChatRoomController, :update

    # User management API
    resources "/users", UserController, except: [:new, :edit] do
      get "/metadata", UserController, :metadata, as: :user_metadata
      put "/metadata", UserController, :update_metadata, as: :user_metadata
    end

    post "/users/authenticate", UserController, :authenticate
    get "/users/type/:type", UserController, :by_type
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
