defmodule GitGud.MCP.PersonalAccessTokenAuthTest do
  @moduledoc """
  Endpoint-level tests for personal access token authentication and the MCP
  scope gate (see `guides/MCP.md` §9 and §11, Phase 5).

  Exercises the real `POST /api/mcp` transport so that the credential
  resolution (`GitGud.MCP.AuthPlug`) and the tool filtering
  (`GitGud.MCP.ServerHelpers`) are covered end to end.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias GitGud.PersonalAccessToken
  alias GitGud.User

  @protocol "2025-06-18"
  @client_info %{"name" => "gitfrank-test", "version" => "0.0.0"}

  setup do
    %{user: User.create!(factory(:user))}
  end

  describe "personal access token authentication" do
    test "a bearer PAT authenticates the initialize handshake", %{user: user} do
      plaintext = create_token(user, ["user:read"])

      {conn, [session_id]} = initialize!(plaintext)

      assert conn.status == 200
      assert is_binary(session_id)
      assert conn.resp_body =~ "protocolVersion"
    end

    test "the X-Api-Key header is accepted as well", %{user: user} do
      plaintext = create_token(user, ["user:read"])

      conn =
        build_conn()
        |> headers(nil, nil)
        |> put_req_header("x-api-key", plaintext)
        |> post("/api/mcp", rpc_body("initialize", initialize_params(), 1))

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end

    test "whoami works with a user:read token", %{user: user} do
      plaintext = create_token(user, ["user:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn =
        rpc("tools/call", %{"name" => "whoami", "arguments" => %{}}, 2, session_id, plaintext)

      assert conn.status == 200
      assert %{"result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(conn.resp_body)
      assert %{"ok" => true, "data" => data} = Jason.decode!(text)
      assert data["id"] == user.id
      assert data["login"] == user.login
    end

    test "a revoked token is rejected with a JSON-RPC 401", %{user: user} do
      {token, plaintext} = create_token_full(user, ["user:read"])
      {:ok, _token} = PersonalAccessToken.revoke(token)

      conn =
        build_conn()
        |> headers(nil, plaintext)
        |> post("/api/mcp", rpc_body("initialize", initialize_params(), 1))

      assert conn.status == 401
      assert %{"error" => %{"message" => "Unauthorized"}} = Jason.decode!(conn.resp_body)
    end

    test "an expired token is rejected with a JSON-RPC 401", %{user: user} do
      expires_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {_token, plaintext} = create_token_full(user, ["user:read"], expires_at)

      conn =
        build_conn()
        |> headers(nil, plaintext)
        |> post("/api/mcp", rpc_body("initialize", initialize_params(), 1))

      assert conn.status == 401
    end
  end

  describe "scope gate" do
    test "tools/list only exposes the tools the token's scopes grant", %{user: user} do
      plaintext = create_token(user, ["issue:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn = rpc("tools/list", %{}, 2, session_id, plaintext)

      assert conn.status == 200
      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)

      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == [
               "get_issue",
               "list_issue_comments",
               "list_issues"
             ]
    end

    test "a narrow token cannot see issue write tools", %{user: user} do
      plaintext = create_token(user, ["user:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn = rpc("tools/list", %{}, 2, session_id, plaintext)

      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == ["whoami"]
    end

    test "a repo:read token alone cannot enumerate users via search", %{user: user} do
      plaintext = create_token(user, ["repo:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn = rpc("tools/list", %{}, 2, session_id, plaintext)

      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()
      assert "search_repositories" in names
      refute "search" in names
    end

    test "session/bearer credentials expose every tool", %{user: user} do
      token = Phoenix.Token.sign(GitGud.Web.Endpoint, "bearer", user.id)
      {_conn, [session_id]} = initialize!(token)
      notify(session_id, token)

      conn = rpc("tools/list", %{}, 2, session_id, token)

      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
      assert length(tools) == 22
    end

    test "tools/call outside the granted scopes fails with insufficient_scope", %{user: user} do
      plaintext = create_token(user, ["issue:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn =
        rpc(
          "tools/call",
          %{"name" => "create_issue", "arguments" => %{}},
          2,
          session_id,
          plaintext
        )

      assert conn.status in [200, 400]

      assert %{"error" => %{"message" => "insufficient_scope"} = error} =
               Jason.decode!(conn.resp_body)

      assert error["data"]["required"] == "issue:write"
      assert error["data"]["tool"] == "create_issue"
    end

    test "tools/call within the granted scopes is delegated", %{user: user} do
      plaintext = create_token(user, ["user:read"])
      {_conn, [session_id]} = initialize!(plaintext)
      notify(session_id, plaintext)

      conn =
        rpc("tools/call", %{"name" => "whoami", "arguments" => %{}}, 2, session_id, plaintext)

      assert conn.status == 200
      assert %{"result" => %{}} = Jason.decode!(conn.resp_body)
    end
  end

  #
  # Helpers
  #

  defp create_token(user, scopes) do
    {_token, plaintext} = create_token_full(user, scopes)
    plaintext
  end

  defp create_token_full(user, scopes, expires_at \\ nil) do
    params = %{name: "test token", scopes: scopes}
    params = if expires_at, do: Map.put(params, :expires_at, expires_at), else: params
    PersonalAccessToken.create!(user, params)
  end

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

  defp notify(session_id, token) do
    build_conn()
    |> headers(session_id, token)
    |> post(
      "/api/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    )
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
