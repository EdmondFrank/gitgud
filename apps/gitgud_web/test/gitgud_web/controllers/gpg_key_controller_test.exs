defmodule GitGud.Web.GPGKeyControllerTest do
  use GitGud.Web.ConnCase, async: true
  use GitGud.Web.DataFactory

  alias GitGud.DB
  alias GitGud.User
  alias GitGud.GPGKey

  import GitGud.Web.GPGKeyView

  setup :create_user

  test "renders gpg authentication key creation form if authenticated", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = get(conn, Routes.gpg_key_path(conn, :new))
    assert html_response(conn, 200) =~ ~s(<h2 class="subtitle">Add a new GPG key</h2>)
  end

  test "fails to render gpg authentication key creation form if not authenticated", %{conn: conn} do
    conn = get(conn, Routes.gpg_key_path(conn, :new))
    assert html_response(conn, 401) =~ "Unauthorized"
  end

  @tag :skip
  test "creates gpg authentication key with valid params", %{conn: conn, user: user} do
    gpg_key_params = factory(:gpg_key, user)
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = post(conn, Routes.gpg_key_path(conn, :create), gpg_key: gpg_key_params)
    assert String.match?(get_flash(conn, :info), ~r/^GPG key 0x[A-F0-9]{4}:[A-F0-9]{4}:[A-F0-9]{4}:[A-F0-9]{4} added.$/)
    assert redirected_to(conn) == Routes.gpg_key_path(conn, :index)
  end

  @tag :skip
  test "fails to create gpg authentication key with invalid public key", %{conn: conn, user: user} do
    gpg_key_params = factory(:gpg_key, user)
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = post(conn, Routes.gpg_key_path(conn, :create), gpg_key: Map.put(gpg_key_params, :data, "-----BEGIN PGP PUBLIC KEY BLOCK-----\n-----END PGP PUBLIC KEY BLOCK-----\n"))
    assert get_flash(conn, :error) == "Something went wrong! Please check error(s) below."
    assert html_response(conn, 400) =~ ~s(<h2 class="subtitle">Add a new GPG key</h2>)
  end

  describe "when gpg authentication keys exist" do
    setup :create_gpg_keys

    @tag :skip
    test "renders user gpg authentication keys", %{conn: conn, user: user, gpg_keys: gpg_keys} do
      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      conn = get(conn, Routes.gpg_key_path(conn, :index))
      assert html_response(conn, 200) =~ ~s(<h2 class="subtitle">GPG keys</h2>)
      for gpg_key <- gpg_keys do
        assert html_response(conn, 200) =~ ~s(<code class=\"is-size-7\">0x#{format_key_id(gpg_key.key_id)}</code>)
      end
    end

    @tag :skip
    test "deletes keys", %{conn: conn, user: user, gpg_keys: gpg_keys} do
      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      for gpg_key <- gpg_keys do
        conn = delete(conn, Routes.gpg_key_path(conn, :delete), gpg_key: %{id: to_string(gpg_key.id)})
        assert get_flash(conn, :info) == "GPG key 0x#{format_key_id(gpg_key.key_id)} deleted."
        assert redirected_to(conn) == Routes.gpg_key_path(conn, :index)
      end
    end
  end

  #
  # Helpers
  #

  defp create_user(context) do
    Map.put(context, :user, User.create!(factory(:user)))
  end

  defp create_gpg_keys(context) do
    gpg_keys = Stream.repeatedly(fn -> GPGKey.create!(factory(:gpg_key, context.user)) end)
    context
    |> Map.put(:gpg_keys, Enum.take(gpg_keys, 2))
    |> Map.update!(:user, &DB.preload(&1, :gpg_keys))
  end
end
