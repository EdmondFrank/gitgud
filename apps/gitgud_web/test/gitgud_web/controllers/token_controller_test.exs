defmodule GitGud.Web.TokenControllerTest do
  use GitGud.Web.ConnCase, async: true
  use GitGud.Web.DataFactory

  alias GitGud.User
  alias GitGud.PersonalAccessToken
  alias GitGud.PersonalAccessTokenQuery

  alias GitGud.Web.LayoutView

  setup :create_user

  test "renders access token creation form if authenticated", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = get(conn, Routes.token_path(conn, :new))
    assert {:ok, html} = Floki.parse_document(html_response(conn, 200))
    assert Floki.text(Floki.find(html, "title")) == LayoutView.title(conn)
  end

  test "fails to render access token creation form if not authenticated", %{conn: conn} do
    conn = get(conn, Routes.token_path(conn, :new))
    assert {:ok, html} = Floki.parse_document(html_response(conn, 401))
    assert Floki.text(Floki.find(html, "title")) == Plug.Conn.Status.reason_phrase(401)
  end

  test "creates an access token and reveals the plaintext once", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, user_id: user.id)

    conn =
      post(conn, Routes.token_path(conn, :create),
        token: %{"name" => "AiderDesk", "scopes" => ["repo:read", "issue:write", ""]}
      )

    assert response = html_response(conn, 200)
    assert response =~ "AiderDesk"
    assert response =~ "repo:read"

    assert [token] = PersonalAccessTokenQuery.user_tokens(user)
    assert token.name == "AiderDesk"
    assert token.scopes == ["repo:read", "issue:write"]
  end

  test "fails to create an access token without scopes", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, user_id: user.id)

    conn =
      post(conn, Routes.token_path(conn, :create),
        token: %{"name" => "AiderDesk", "scopes" => [""]}
      )

    assert get_flash(conn, :error) == "Something went wrong! Please check error(s) below."
    assert {:ok, html} = Floki.parse_document(html_response(conn, 400))
    assert Floki.text(Floki.find(html, "title")) == LayoutView.title(conn)
  end

  test "lists the user's access tokens", %{conn: conn, user: user} do
    PersonalAccessToken.create!(user, %{name: "one", scopes: ["repo:read"]})
    PersonalAccessToken.create!(user, %{name: "two", scopes: ["user:read"]})

    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = get(conn, Routes.token_path(conn, :index))

    assert {:ok, html} = Floki.parse_document(html_response(conn, 200))
    assert Floki.text(Floki.find(html, "title")) == LayoutView.title(conn)

    tokens =
      html |> Floki.find(".card .card-header-title") |> Enum.map(&String.trim(Floki.text(&1)))

    assert "one" in tokens
    assert "two" in tokens
  end

  test "deletes an access token", %{conn: conn, user: user} do
    {token, _plaintext} =
      PersonalAccessToken.create!(user, %{name: "AiderDesk", scopes: ["repo:read"]})

    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = delete(conn, Routes.token_path(conn, :delete), token: %{id: to_string(token.id)})

    assert get_flash(conn, :info) == "Access token 'AiderDesk' deleted."
    assert redirected_to(conn) == Routes.token_path(conn, :index)
    assert PersonalAccessTokenQuery.user_tokens(user) == []
  end

  #
  # Helpers
  #

  defp create_user(context) do
    Map.put(context, :user, User.create!(factory(:user)))
  end
end
