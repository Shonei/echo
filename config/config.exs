# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :echo,
  ecto_repos: [Echo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Who answers a conversation's $.name placeholders. Read at call time rather
# than referenced directly, because Echo.Skills already calls Echo.Agents --
# naming it back would be a compile-time cycle. See
# Echo.Agents.VariableResolver.
config :echo, :variable_resolver, Echo.Skills.Variables

# Configures the endpoint
config :echo, EchoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EchoWeb.ErrorHTML, json: EchoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Echo.PubSub,
  live_view: [signing_salt: "dfCqDFc3"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  echo: [
    args:
      ~w(js/app.js js/chat.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  echo: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configures CORS
config :cors_plug,
  origin: ["localhost"],
  max_age: 86400,
  methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS", "PUT"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
