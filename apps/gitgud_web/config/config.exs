import Config

# General application configuration
config :gitgud_web,
  namespace: GitGud.Web,
  ecto_repos: [GitGud.DB]

# Configures the endpoint
config :gitgud_web, GitGud.Web.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "Orcr/BYzysTwrdJaOA7vu7miC2V5M2ivU6yMY7hW1cUnegxFej5GLalozFC+f6uA",
  live_view: [signing_salt: "+GxMLCpWTHUwhpTzG0SBr+DULSa+gzYA"],
  render_errors: [formats: [html: GitGud.Web.ErrorHTML], layout: {GitGud.Web.Layouts, :error}],
  pubsub_server: GitGud.Web.PubSub,
  server: true

# Configures Waffle File Uploader
config :waffle,
  storage: Waffle.Storage.Local,
  storage_dir: "/uploads",
  storage_dir_prefix: "priv/static/avatar",
  priv_storage_dir_prefix: "priv/static/asset"

# Configure generators
config :gitgud_web, :generators, context_app: :gitgud

# Absinthe GraphQL schema
config :absinthe, schema: GitGud.GraphQL.Schema

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Use Jason for JSON parsing in Bamboo
config :bamboo, :json_library, Jason

# AI-native MCP server (see guides/MCP.md).
#
# `enabled` and `path` are resolved from the environment at **build time**: the
# router mounts the endpoint with `Application.compile_env/3`, so they cannot be
# changed at runtime. Set `MCP_ENABLED=false` to compile the endpoint out, or
# `MCP_PATH=...` to relocate it.
config :gitgud_web, :mcp,
  enabled: System.get_env("MCP_ENABLED", "true") == "true",
  path: System.get_env("MCP_PATH", "/api/mcp"),
  server_name: "gitfrank",
  server_version: "1.0.0",
  request_timeout: 600_000,
  session_idle_timeout: 86_400_000 * 365,
  telemetry: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
