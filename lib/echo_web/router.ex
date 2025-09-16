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
  end

  scope "/echo", EchoWeb do
    pipe_through :browser

    get "/request", UIController, :requests
    get "/request/:id", UIController, :request_detail
  end

  scope "/echo", EchoWeb do
    pipe_through :echo
    forward "/", RequestController, :any
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
