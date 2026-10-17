defmodule GitGud.MCP.AuthPlug do
  @moduledoc """
  Authentication plug for the MCP endpoint (`POST /api/mcp`).

  Credential resolution is delegated to `GitGud.Web.AuthenticationPlug`, so the
  MCP endpoint accepts the same credentials as the rest of gitfrank — a bearer
  `Phoenix.Token` (24h), a personal access token (added in Phase 5), or the
  `:user_id` session cookie (for the browser playground).

  Unlike the generic plug, an unauthenticated request is halted with a
  **JSON-RPC 401** body (plus a `WWW-Authenticate` challenge) instead of an HTML
  error page, because MCP clients expect a machine-readable response.

  The resolved user is left in `conn.assigns.current_user`. Anubis copies
  `Plug.Conn.assigns` into the transport context, and the session merges that
  into every tool frame's `assigns`, so tools read it as
  `frame.assigns[:current_user]`.

  See `guides/MCP.md` §8.
  """

  @behaviour Plug

  import Plug.Conn

  alias GitGud.PersonalAccessToken
  alias GitGud.Web.AuthenticationPlug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn =
      conn
      |> AuthenticationPlug.authenticate_bearer_token([])
      |> AuthenticationPlug.authenticate_personal_access_token([])

    conn =
      if AuthenticationPlug.authenticated?(conn),
        do: conn,
        else: AuthenticationPlug.authenticate_session(conn, [])

    conn
    |> assign_scopes()
    |> ensure_authenticated()
  end

  #
  # Helpers
  #

  # Exposes the granted scopes to the MCP layer (`frame.assigns[:mcp_scopes]`).
  # A `nil` value means "unrestricted" and is used for session / bearer
  # credentials, which are already trusted to act as the user themselves.
  defp assign_scopes(conn) do
    scopes =
      case conn.assigns[:personal_access_token] do
        %PersonalAccessToken{scopes: scopes} -> scopes
        _other -> nil
      end

    assign(conn, :mcp_scopes, scopes)
  end

  defp ensure_authenticated(conn) do
    if AuthenticationPlug.authenticated?(conn) do
      conn
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="gitfrank-mcp"))
      |> put_resp_content_type("application/json")
      |> send_resp(:unauthorized, Jason.encode!(unauthorized_body(request_id(conn))))
      |> halt()
    end
  end

  # Echo the JSON-RPC request id when the body was already parsed, so a client
  # can correlate the 401 with the failed call.
  defp request_id(conn) do
    case conn.body_params do
      %{"id" => id} -> id
      _other -> nil
    end
  end

  defp unauthorized_body(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32001,
        "message" => "Unauthorized",
        "data" => %{"reason" => "missing_or_invalid_credentials"}
      }
    }
  end
end
