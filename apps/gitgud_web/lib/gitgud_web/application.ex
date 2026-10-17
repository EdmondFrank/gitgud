defmodule GitGud.Web.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    telemetry_attach_mcp()

    children =
      [
        {Phoenix.PubSub, name: GitGud.Web.PubSub},
        GitGud.Web.Endpoint,
        GitGud.Web.Presence
      ] ++ mcp_children()

    opts = [strategy: :one_for_one, name: GitGud.Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    GitGud.Web.Endpoint.config_change(changed, removed)
    :ok
  end

  #
  # Helpers
  #

  # Attaches the MCP tool-call logger handler (see `GitGud.MCP.Telemetry`).
  defp telemetry_attach_mcp do
    config = mcp_config()

    if config[:enabled] && config[:telemetry] != false do
      :telemetry.attach_many(
        "mcp-tool-call",
        [
          GitGud.MCP.Telemetry.event_prefix() ++ [:start],
          GitGud.MCP.Telemetry.event_prefix() ++ [:stop]
        ],
        &GitGud.MCP.Telemetry.LoggerHandler.handle_event/4,
        %{}
      )
    end

    :ok
  end

  defp mcp_children do
    config = mcp_config()

    if config[:enabled] do
      [
        {
          GitGud.MCP.Server,
          # `start: true` forces the Anubis transport to boot regardless of
          # whether Anubis detects a running HTTP server (it does not under
          # `MIX_ENV=test`, where the Phoenix endpoint has `server: false`).
          transport: {:streamable_http, [start: true]},
          request_timeout: config[:request_timeout] || 600_000,
          session_idle_timeout: config[:session_idle_timeout] || 86_400_000 * 365
        }
      ]
    else
      []
    end
  end

  defp mcp_config, do: Application.get_env(:gitgud_web, :mcp, [])
end
