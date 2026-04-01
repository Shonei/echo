defmodule Echo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Configure Axiom logger if enabled
    setup_axiom_logging()

    children =
      [
        EchoWeb.Telemetry,
        Echo.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:echo, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:echo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Echo.PubSub},
        Echo.RequestCache,
        # Cleanup job for old HTTP requests
        Echo.Requests.RequestCleanupJob,
        # Rate limiting ETS table owner
        EchoWeb.Plugs.RateLimit.TableOwner,
        # Auth User GenServer
        Echo.AuthUser,
        # Gemini API GenServer
        Echo.Agents.API,
        # AI Conversation Manager Processes (Dynamic)
        {Registry, keys: :unique, name: Echo.Agents.ConversationRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Echo.Agents.ConversationSupervisor},
        # HTTP client
        {Finch, name: Echo.Finch},
        # Start to serve requests, typically the last entry
        EchoWeb.Endpoint
      ] ++ axiom_logger_child()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Echo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EchoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end

  defp axiom_logger_child do
    if Echo.AxiomConfig.enabled?() do
      try do
        Echo.AxiomConfig.validate_config!()
        [{Echo.AxiomLogger, Echo.AxiomConfig.logger_config()}]
      rescue
        error ->
          Logger.error("Failed to setup Axiom logging: #{inspect(error)}")
          []
      end
    else
      []
    end
  end


  defp setup_axiom_logging do
    if Echo.AxiomConfig.enabled?() do
      # Install a custom logger handler that forwards to our GenServer
      :logger.add_handler(:axiom_forwarder, Echo.AxiomLoggerHandler, %{})

      Logger.info(
        "Axiom logging enabled - logs will be sent to dataset: #{Echo.AxiomConfig.get_dataset()}"
      )
    else
      Logger.debug("Axiom logging disabled")
    end
  end
end
