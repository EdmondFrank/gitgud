defmodule GitGud.MCP.Telemetry.LoggerHandler do
  @moduledoc false

  require Logger

  def handle_event([:gitgud, :mcp, :tool, :call, :start], _measurements, _metadata, _config),
    do: :ok

  def handle_event([:gitgud, :mcp, :tool, :call, :stop], %{duration: duration}, metadata, _config) do
    Logger.debug(
      "[MCP] tools/call #{metadata.tool} → #{metadata.result} in #{duration_inspect(duration / 1_000)}" <>
        scopes_suffix(metadata)
    )
  end

  #
  # Helpers
  #

  defp scopes_suffix(%{scopes: scopes}) when is_list(scopes),
    do: " (scopes: #{Enum.join(scopes, ", ")})"

  defp scopes_suffix(_metadata), do: ""

  defp duration_inspect(duration) do
    cond do
      duration > 1_000_000 -> "#{Float.round(duration / 1_000_000, 2)} s"
      duration > 1_000 -> "#{Float.round(duration / 1_000, 2)} ms"
      true -> "#{Float.round(duration, 2)} µs"
    end
  end
end
