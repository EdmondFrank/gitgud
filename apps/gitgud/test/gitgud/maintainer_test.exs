defmodule GitGud.MaintainerTest do
  use GitGud.DataCase, async: true
  use GitGud.DataFactory

  alias GitGud.User
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.Maintainer

  setup [:create_users, :create_repo]

  test "creates a new repository maintainer with valid params", %{users: [_user1, user2], repo: repo} do
    assert {:ok, maintainer} = Repo.add_maintainer(repo, user_id: user2.id)
    assert maintainer.permission == "read"
  end

  test "fails to create a new repository maintainer with invalid permission", %{users: [_user1, user2], repo: repo} do
    assert {:error, changeset} = Repo.add_maintainer(repo, user_id: user2.id, permission: "foobar")
    assert "is invalid" in errors_on(changeset).permission
  end

  describe "when repository maintainer exists" do
    setup :create_maintainer

    test "updates maintainer permission with valid permission", %{maintainer: maintainer1} do
      assert {:ok, maintainer2} = Maintainer.update_permission(maintainer1, "write")
      assert maintainer2.permission == "write"
    end

    test "fails to update maintainer permission with invalid permission", %{maintainer: maintainer} do
      assert {:error, changeset} = Maintainer.update_permission(maintainer, "foobar")
      assert "is invalid" in errors_on(changeset).permission
    end

    test "deletes maintainer", %{maintainer: maintainer1} do
      assert {:ok, maintainer2} = Maintainer.delete(maintainer1)
      assert maintainer2.__meta__.state == :deleted
    end
  end

  #
  # Helpers
  #

  defp create_users(context) do
    users = Stream.repeatedly(fn -> User.create!(factory(:user)) end)
    users = Enum.take(users, 2)
    on_exit fn ->
      File.rmdir(Path.join(Keyword.fetch!(Application.get_env(:gitgud, RepoStorage), :git_root), hd(users).login))
    end
    Map.put(context, :users, users)
  end

  defp create_repo(context) do
    repo = Repo.create!(hd(context.users), factory(:repo))
    on_exit fn ->
      File.rm_rf(RepoStorage.workdir(repo))
    end
    Map.put(context, :repo, repo)
  end

  defp create_maintainer(context) do
    maintainer = Repo.add_maintainer!(context.repo, user_id: List.last(context.users).id)
    context
    |> Map.put(:maintainer, maintainer)
    |> Map.update!(:repo, &DB.preload(&1, :maintainers))
  end
end
