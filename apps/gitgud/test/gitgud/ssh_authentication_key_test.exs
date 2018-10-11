defmodule GitGud.SSHAuthenticationKeyTest do
  use GitGud.DataCase, async: true
  use GitGud.DataFactory

  alias GitGud.User
  alias GitGud.SSHAuthenticationKey

  setup :create_user

  test "creates a new ssh authentication key with valid params", %{user: user} do
    assert {:ok, ssh_key} = SSHAuthenticationKey.create(factory(:ssh_authentication_key, user))
    assert [{key, _attrs}] = :public_key.ssh_decode(ssh_key.data, :public_key)
    assert ssh_key.fingerprint == to_string(:public_key.ssh_hostkey_fingerprint(key))
  end

  test "fails to create a new ssh authentication key with invalid ssh public key", %{user: user} do
    params = factory(:ssh_authentication_key, user)
    assert {:error, changeset} = SSHAuthenticationKey.create(Map.delete(params, :data))
    assert "can't be blank" in errors_on(changeset).data
    assert {:error, changeset} = SSHAuthenticationKey.create(Map.update!(params, :data, &binary_part(&1, 0, 12)))
    assert "invalid" in errors_on(changeset).data
  end

  #
  # Helpers
  #

  defp create_user(context) do
    Map.put(context, :user, User.create!(factory(:user)))
  end
end
