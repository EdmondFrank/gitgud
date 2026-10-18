import Config

# General application configuration
config :gitgud,
  namespace: GitGud,
  ecto_repos: [GitGud.DB]

# Configure Telemetry prefix for Ecto repository GitGud.DB
config :gitgud, GitGud.DB, telemetry_prefix: [:gitgud, :db]

# Configure AI coding-agent checkpoints, the way the Entire CLI pushes them to
# gitfrank as `refs/entire/checkpoints/*` (see
# `guides/Sessions and Checkpoints.md`).
config :gitgud, GitGud.Checkpoints,
  enabled: true,
  legacy_branch: "entire/checkpoints/v1",
  max_transcript_bytes: 1_048_576

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env}.exs"
