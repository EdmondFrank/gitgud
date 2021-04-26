defmodule GitGud.Web.SSHKeyControllerTest do
  use GitGud.Web.ConnCase, async: true
  use GitGud.Web.DataFactory

  alias GitGud.User
  alias GitGud.SSHKey

  setup :create_user

  test "renders ssh authentication key creation form if authenticated", %{conn: conn, user: user} do
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = get(conn, Routes.ssh_key_path(conn, :new))
    assert html_response(conn, 200) =~ ~s(<h2 class="subtitle">Add a new SSH key</h2>)
  end

  test "fails to render ssh authentication key creation form if not authenticated", %{conn: conn} do
    conn = get(conn, Routes.ssh_key_path(conn, :new))
    assert html_response(conn, 401) =~ "Unauthorized"
  end

  test "creates ssh authentication key with valid params", %{conn: conn, user: user} do
    ssh_key_params = factory(:ssh_key)
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = post(conn, Routes.ssh_key_path(conn, :create), ssh_key: ssh_key_params)
    assert get_flash(conn, :info) == "SSH key '#{ssh_key_params.name}' added."
    assert redirected_to(conn) == Routes.ssh_key_path(conn, :index)
  end

  test "fails to create ssh authentication key with invalid public key", %{conn: conn, user: user} do
    ssh_key_params = factory(:ssh_key)
    conn = Plug.Test.init_test_session(conn, user_id: user.id)
    conn = post(conn, Routes.ssh_key_path(conn, :create), ssh_key: Map.update!(ssh_key_params, :data, &binary_part(&1, 0, 12)))
    assert get_flash(conn, :error) == "Something went wrong! Please check error(s) below."
    assert html_response(conn, 400) =~ ~s(<h2 class="subtitle">Add a new SSH key</h2>)
  end

  describe "when ssh authentication keys exist" do
    setup :create_ssh_keys

    test "renders user ssh authentication keys", %{conn: conn, user: user, ssh_keys: ssh_keys} do
      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      conn = get(conn, Routes.ssh_key_path(conn, :index))
      assert html_response(conn, 200) =~ ~s(<h2 class="subtitle">SSH keys</h2>)
      for ssh_key <- ssh_keys do
        assert html_response(conn, 200) =~ ~s(<code class=\"is-size-7\">#{ssh_key.fingerprint}</code>)
      end
    end

    test "deletes keys", %{conn: conn, user: user, ssh_keys: ssh_keys} do
      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      for ssh_key <- ssh_keys do
        conn = delete(conn, Routes.ssh_key_path(conn, :delete), ssh_key: %{id: to_string(ssh_key.id)})
        assert get_flash(conn, :info) == "SSH key '#{ssh_key.name}' deleted."
        assert redirected_to(conn) == Routes.ssh_key_path(conn, :index)
      end
    end
  end

  #
  # Helpers
  #

  defp create_user(context) do
    Map.put(context, :user, User.create!(factory(:user)))
  end

  defp create_ssh_keys(context) do
    ssh_keys = Stream.repeatedly(fn -> SSHKey.create!(context.user, factory(:ssh_key)) end)
    Map.put(context, :ssh_keys, Enum.take(ssh_keys, 2))
  end
end
