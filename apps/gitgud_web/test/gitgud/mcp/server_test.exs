defmodule GitGud.MCP.ServerTest do
  @moduledoc """
  Tests for the `/api/mcp` Streamable HTTP endpoint (see `guides/MCP.md`).

  Phase 1 covers the transport handshake; Phase 2 adds the authentication gate
  (bearer token / session cookie) and the `whoami` tool that proves the resolved
  user reaches the tool frame.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias GitGud.User

  @protocol "2025-06-18"
  @client_info %{"name" => "gitgud-test", "version" => "0.0.0"}

  setup do
    user = User.create!(factory(:user))

    %{
      user: user,
      token: Phoenix.Token.sign(GitGud.Web.Endpoint, "bearer", user.id)
    }
  end

  describe "unauthenticated" do
    test "initialize is rejected with a JSON-RPC 401", %{conn: conn} do
      conn =
        conn
        |> headers(nil, nil)
        |> post("/api/mcp", rpc_body("initialize", initialize_params(), 7))

      assert conn.status == 401
      assert [www_auth | _] = get_resp_header(conn, "www-authenticate")
      assert www_auth =~ "Bearer"

      assert %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{"code" => -32001, "message" => "Unauthorized"}
             } = Jason.decode!(conn.resp_body)
    end
  end

  describe "bearer token" do
    test "initialize handshake advertises the gitfrank server", %{token: token} do
      {conn, [session_id]} = initialize!(token)

      assert conn.status == 200
      assert is_binary(session_id)
      assert conn.resp_body =~ "gitfrank"
      assert conn.resp_body =~ "protocolVersion"
    end

    test "tools/list returns the registered tools after initialization", %{token: token} do
      {conn, [session_id]} = initialize!(token)
      assert conn.status == 200

      assert %{status: 202} = notify("notifications/initialized", session_id, token)

      conn = rpc("tools/list", %{}, 2, session_id, token)

      assert conn.status == 200
      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
      assert "whoami" in names
      assert "get_repository" in names
      assert "create_issue" in names
      assert "get_checkpoint" in names
      assert length(names) == 26
    end

    test "whoami returns the authenticated user", %{token: token, user: user} do
      {_conn, [session_id]} = initialize!(token)
      notify("notifications/initialized", session_id, token)

      conn = rpc("tools/call", %{"name" => "whoami", "arguments" => %{}}, 2, session_id, token)

      assert conn.status == 200
      assert %{"result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(conn.resp_body)
      assert %{"ok" => true, "data" => data} = Jason.decode!(text)
      assert data["id"] == user.id
      assert data["login"] == user.login
    end

    test "an unknown JSON-RPC method returns an error", %{token: token} do
      {_conn, [session_id]} = initialize!(token)
      notify("notifications/initialized", session_id, token)

      conn = rpc("no/such_method", %{}, 3, session_id, token)

      assert conn.status in [200, 400]
      assert %{"error" => %{}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "session cookie" do
    test "a session authenticated user can initialize", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(user_id: user.id)
        |> headers(nil, nil)
        |> post("/api/mcp", rpc_body("initialize", initialize_params(), 1))

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
  end

  #
  # Helpers
  #

  defp initialize!(token) do
    conn =
      build_conn()
      |> headers(nil, token)
      |> post("/api/mcp", rpc_body("initialize", initialize_params(), 1))

    {conn, get_resp_header(conn, "mcp-session-id")}
  end

  defp initialize_params do
    %{"protocolVersion" => @protocol, "capabilities" => %{}, "clientInfo" => @client_info}
  end

  defp rpc_body(method, params, id) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp rpc(method, params, id, session_id, token) do
    build_conn()
    |> headers(session_id, token)
    |> post("/api/mcp", rpc_body(method, params, id))
  end

  defp notify(method, session_id, token) do
    build_conn()
    |> headers(session_id, token)
    |> post("/api/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => method}))
  end

  defp headers(conn, session_id, token) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", @protocol)
    |> maybe_session(session_id)
    |> maybe_auth(token)
  end

  defp maybe_session(conn, nil), do: conn
  defp maybe_session(conn, session_id), do: put_req_header(conn, "mcp-session-id", session_id)

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
