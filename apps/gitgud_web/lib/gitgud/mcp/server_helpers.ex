defmodule GitGud.MCP.ServerHelpers do
  @moduledoc """
  Shared helpers for the gitfrank MCP server.

  Provides `filter_tools_by_headers/2`, which filters the `tools/list` response
  using the `x-include-tools` and `x-exclude-tools` request headers, so a client
  can scope the exposed toolset per connection.

  It also applies the **scope gate**: when the caller authenticated with a
  personal access token, `tools/list` only exposes (and `tools/call` only
  invokes) the tools the token's scopes grant (see `guides/MCP.md` §9).

  ## Headers

  - `x-include-tools` – Comma-separated list of tool names to include. When
    present, only these tools are returned.
  - `x-exclude-tools` – Comma-separated list of tool names to exclude. Applied
    after the include filter.

  Both headers are case-insensitive and values are trimmed.

  Adapted from `Exhub.MCP.ServerHelpers` (see `~/Code/exhub`).
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Telemetry

  @doc """
  Filters a list of `tools` based on the `x-include-tools` / `x-exclude-tools`
  headers found in the request context.

  ## Examples

      iex> tools = [%{name: "get_repository"}, %{name: "create_issue"}]
      iex> headers = %{"x-include-tools" => "get_repository"}
      iex> GitGud.MCP.ServerHelpers.filter_tools_by_headers(tools, headers)
      [%{name: "get_repository"}]
  """
  @spec filter_tools_by_headers([map()], %{optional(String.t()) => String.t()}) :: [map()]
  def filter_tools_by_headers(tools, headers) when is_list(tools) do
    include = parse_tool_list(headers["x-include-tools"])
    exclude = parse_tool_list(headers["x-exclude-tools"])

    tools
    |> maybe_include(include)
    |> maybe_exclude(exclude)
  end

  @doc """
  Wraps the default Anubis request handler to filter `tools/list` responses
  based on the `x-include-tools` / `x-exclude-tools` headers, and to enforce the
  personal access token scope gate on both `tools/list` and `tools/call`.
  """
  @spec handle_request_with_filtered_tools(module(), map(), Frame.t()) ::
          {:reply, map(), Frame.t()}
          | {:noreply, Frame.t()}
          | {:error, term(), Frame.t()}
  def handle_request_with_filtered_tools(server_module, request, frame) do
    scopes = scopes(frame)

    case request do
      %{"method" => "tools/list"} ->
        case Anubis.Server.Handlers.handle(request, server_module, frame) do
          {:reply, %{"tools" => tools} = response, new_frame} ->
            headers = new_frame.context.headers

            filtered_tools =
              tools
              |> filter_tools_by_headers(headers)
              |> filter_tools_by_scopes(scopes)

            {:reply, %{response | "tools" => filtered_tools}, new_frame}

          other ->
            other
        end

      %{"method" => "tools/call", "params" => %{"name" => tool_name}} ->
        Telemetry.span(tool_call_metadata(tool_name, frame, scopes), fn ->
          case Authorization.authorize_tool(scopes, tool_name) do
            :ok ->
              tag_result(Anubis.Server.Handlers.handle(request, server_module, frame))

            {:error, :insufficient_scope} ->
              {{:error,
                Error.execution("insufficient_scope", %{
                  tool: tool_name,
                  required: Authorization.required_scope(tool_name),
                  granted: scopes
                }), frame}, :denied}
          end
        end)

      _other ->
        Anubis.Server.Handlers.handle(request, server_module, frame)
    end
  end

  #
  # Helpers
  #

  defp parse_tool_list(nil), do: []
  defp parse_tool_list(""), do: []

  defp parse_tool_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_include(tools, []), do: tools

  defp maybe_include(tools, include) do
    include_set = MapSet.new(include)
    Enum.filter(tools, &MapSet.member?(include_set, tool_name(&1)))
  end

  defp maybe_exclude(tools, []), do: tools

  defp maybe_exclude(tools, exclude) do
    exclude_set = MapSet.new(exclude)
    Enum.reject(tools, &MapSet.member?(exclude_set, tool_name(&1)))
  end

  defp filter_tools_by_scopes(tools, nil), do: tools

  defp filter_tools_by_scopes(tools, scopes) when is_list(scopes) do
    Enum.filter(tools, &Authorization.visible_tool?(scopes, tool_name(&1)))
  end

  # The scopes granted to the caller: a list for personal access tokens, `nil`
  # (unrestricted) for session/bearer credentials. `GitGud.MCP.AuthPlug` puts
  # the value in `conn.assigns`, which Anubis merges into the frame assigns.
  defp scopes(frame), do: frame.assigns[:mcp_scopes]

  # Telemetry metadata for a `tools/call` (see `GitGud.MCP.Telemetry`). It never
  # carries the credential itself — only the granted scopes.
  defp tool_call_metadata(tool_name, frame, scopes) do
    %{
      tool: tool_name,
      scopes: scopes,
      user_id: user_id(frame),
      session_id: frame.context.session_id,
      remote_ip: frame.context.remote_ip
    }
  end

  defp tag_result({:error, _error, _frame} = result), do: {result, :error}

  defp tag_result({:reply, response, _frame} = result),
    do: {result, reply_result_tag(response)}

  defp tag_result(result), do: {result, :ok}

  # A tool reply is a JSON envelope (`{"ok": true | false, …}`); an `ok: false`
  # envelope is a domain-level failure, reported as `:error`. Transport errors
  # and the scope gate are handled separately above/below.
  defp reply_result_tag(%{isError: true}), do: :error
  defp reply_result_tag(%{"isError" => true}), do: :error

  defp reply_result_tag(%{content: [%{"text" => text} | _]}) when is_binary(text),
    do: envelope_result_tag(text)

  defp reply_result_tag(%{"content" => [%{"text" => text} | _]}) when is_binary(text),
    do: envelope_result_tag(text)

  defp reply_result_tag(_response), do: :ok

  defp envelope_result_tag(text) do
    case Jason.decode(text) do
      {:ok, %{"ok" => false}} -> :error
      _other -> :ok
    end
  end

  defp user_id(frame) do
    case frame.assigns[:current_user] do
      %{id: id} -> id
      _other -> nil
    end
  end

  defp tool_name(%{name: name}), do: name
  defp tool_name(%{"name" => name}), do: name
end
