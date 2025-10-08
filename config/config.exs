import Config

# By default, the umbrella project as well as each child
# application will require this configuration file, ensuring
# they all use the same configuration. While one could
# configure all applications here, we prefer to delegate
# back to each application for organization purposes.
for config <- Path.wildcard(Path.expand("../apps/*/config/config.exs", __DIR__)) do
  import_config config
end

# Configures Elixir's Logger
config :logger,
  backends: [:console, {LoggerFileBackend, :error_log}, {LoggerFileBackend, :application_log}],
  format: "$time [$level] $message\n",
  metadata: [],
  erl_formatter: {GitGud.CustomLoggerFormatter, :handle_event}


config :logger, :application_log,
  path: "log/application.log",
  level: :info

config :logger, :error_log,
  path: "log/error.log",
  level: :error


# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env}.exs"
