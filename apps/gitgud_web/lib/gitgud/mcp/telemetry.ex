defmodule GitGud.MCP.Telemetry do
  @moduledoc """
  Telemetry for the gitfrank MCP server.

  Each `tools/call` is wrapped in a `:telemetry.span/3`, producing `:start` and
  `:stop` events under the prefix `[:gitgud, :mcp, :tool, :call]`:

    * **Measurements** (`:stop`) — `%{duration: native_time}`.
    * **Metadata** — `%{tool: name, result: result, user_id: id, scopes: scopes,
      session_id: id, remote_ip: ip}` where `result` is `:ok`, `:error`
      (the tool failed or returned an `ok: false` envelope) or `:denied`
      (the scope gate rejected the call).

  `GitGud.MCP.Telemetry.LoggerHandler` is attached by `GitGud.Web.Application`
  unless `:gitgud_web, :mcp, :telemetry` is `false`. See `guides/MCP.md` §11.
  """

  @event [:gitgud, :mcp, :tool, :call]

  @typedoc "Outcome of a tool call, reported as the `:result` metadata key."
  @type result :: :ok | :error | :denied

  @doc "Returns the telemetry event prefix for MCP tool calls."
  @spec event_prefix :: [atom]
  def event_prefix, do: @event

  @doc """
  Wraps a tool call in a telemetry span.

  `fun` must return `{result, result_tag}` where `result_tag` is the outcome
  (see `t:result/0`); the tuple's first element is returned unchanged.
  """
  @spec span(map, (-> {term, result})) :: term
  def span(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(@event, metadata, fn ->
      {result, tag} = fun.()
      {result, Map.put(metadata, :result, tag)}
    end)
  end
end
