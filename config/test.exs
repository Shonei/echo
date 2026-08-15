import Config

# Database URL comes from POSTGRES_URL in config/runtime.exs.
# Tests always use the `echo_test` database so they cannot clobber dev data.
# Writes are committed (no SQL sandbox) so rows accumulate across runs.
config :echo, Echo.Repo, pool_size: System.schedulers_online() * 2

# RequestCleanupJob would delete old echo requests; keep them for index/query work.
config :echo, :request_cleanup_enabled, false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :echo, EchoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "DgLIguPM6/TpLniiz1wVLkJMB11YwsW6qOvrTfd7/R2PFlh5RNpmseYhYWkNFfr6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Disable Axiom logging in tests by default
config :echo, axiom_enabled: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
