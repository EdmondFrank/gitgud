defmodule GitGud.GitReferenceTest do
  @moduledoc """
  Regression coverage for reference namespaces outside `refs/heads/` and
  `refs/tags/` — notably the checkpoints the Entire CLI pushes as
  `refs/entire/checkpoints/<shard>/<id>`.

  Such a reference used to raise `FunctionClauseError` while being classified,
  which took down the whole `info/refs` response (and with it every clone,
  fetch and later push) of any repository that carried one.
  """

  use GitGud.DataCase, async: true
  use GitGud.DataFactory

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias GitRekt.GitAgent
  alias GitRekt.GitRef
  alias GitRekt.GitRepo
  alias GitRekt.WireProtocol

  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.SmartHTTPBackendRouter
  alias GitGud.User

  # A realistic git-refs checkpoint ref: `<shard>` is the last two characters
  # of the 26-character ULID checkpoint id.
  @checkpoint_ref "refs/entire/checkpoints/6D/01K9TQ8ZP7X3F5M2WVJ4CNRB6D"

  setup :create_user
  setup :create_repo

  describe "foreign reference namespaces" do
    setup :create_checkpoint_ref

    test "are classified as :other", %{ref: ref} do
      assert ref.type == :other
      assert to_string(ref) == @checkpoint_ref
    end

    test "are listed by references/1", %{agent: agent, ref: ref} do
      assert {:ok, refs} = GitAgent.references(agent)
      assert Enum.any?(refs, &(&1.type == :other and &1.oid == ref.oid))
    end

    test "are not listed as branches", %{agent: agent} do
      assert {:ok, branches} = GitAgent.branches(agent)
      refute Enum.any?(branches, &(to_string(&1) == @checkpoint_ref))
    end

    test "are advertised during reference discovery", %{agent: agent} do
      lines = WireProtocol.reference_discovery(agent, "git-upload-pack", [])
      assert lines |> Enum.reject(&(&1 == :flush)) |> Enum.join() =~ @checkpoint_ref
    end

    test "resolve together with their target commit", %{agent: agent, commit_oid: commit_oid} do
      assert {:ok, refs} = GitAgent.references(agent, with: :commit, target: :commit)

      assert Enum.any?(refs, fn
               {%GitRef{type: :other}, target} -> target.oid == commit_oid
               _other -> false
             end)
    end

    test "are still served by the Smart HTTP `info/refs` endpoint", %{repo: repo, user: user} do
      conn = conn(:get, "/#{repo.owner_login}/#{repo.name}.git/info/refs?service=git-upload-pack")

      conn =
        put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user.login}:qwertz"))

      conn = SmartHTTPBackendRouter.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ @checkpoint_ref
    end
  end

  describe "the default branch" do
    setup :create_checkpoint_ref

    test "still resolves after a foreign reference exists", %{agent: agent} do
      assert {:ok, %GitRef{type: :branch}} = GitAgent.head(agent)
    end
  end

  describe "WireProtocol.valid_reference_name?/1" do
    test "accepts the reference names Git accepts" do
      assert WireProtocol.valid_reference_name?("refs/heads/main")
      assert WireProtocol.valid_reference_name?("refs/tags/v1.0.0")
      assert WireProtocol.valid_reference_name?(@checkpoint_ref)
    end

    test "refuses the names Git forbids" do
      refute WireProtocol.valid_reference_name?("HEAD")
      refute WireProtocol.valid_reference_name?("refs/")
      refute WireProtocol.valid_reference_name?("refs/heads/")
      refute WireProtocol.valid_reference_name?("refs/heads/bad..name")
      refute WireProtocol.valid_reference_name?("refs/heads/.hidden")
      refute WireProtocol.valid_reference_name?("refs/heads/lock.lock")
      refute WireProtocol.valid_reference_name?("refs/heads/a b")
      refute WireProtocol.valid_reference_name?("refs/heads/a~b")
      refute WireProtocol.valid_reference_name?("refs/heads/a@{b")
    end
  end

  #
  # Helpers
  #

  defp create_user(context) do
    user = User.create!(factory(:user))

    on_exit(fn ->
      File.rmdir(
        Path.join(
          Keyword.fetch!(Application.get_env(:gitgud, RepoStorage), :git_root),
          user.login
        )
      )
    end)

    Map.put(context, :user, user)
  end

  defp create_repo(context) do
    repo = Repo.create!(context.user, factory(:repo))

    on_exit(fn ->
      File.rm_rf(RepoStorage.workdir(repo))
    end)

    Map.put(context, :repo, repo)
  end

  defp create_checkpoint_ref(%{repo: repo} = context) do
    {:ok, agent} = GitRepo.get_agent(repo)

    {:ok, oid} =
      GitAgent.transaction(agent, fn agent ->
        signature = %{
          name: "Entire",
          email: "agent@entire.io",
          timestamp: DateTime.now!("Etc/UTC")
        }

        with {:ok, odb} <- GitAgent.odb(agent),
             {:ok, blob_oid} <- GitAgent.odb_write(agent, odb, "hello world\n", :blob),
             {:ok, index} <- GitAgent.index(agent),
             :ok <-
               GitAgent.index_add(
                 agent,
                 index,
                 blob_oid,
                 "README.md",
                 byte_size("hello world\n"),
                 0o100644
               ),
             {:ok, tree_oid} <- GitAgent.index_write_tree(agent, index),
             {:ok, commit_oid} <-
               GitAgent.commit_create(agent, signature, signature, "Initial commit", tree_oid, [],
                 update_ref: "refs/heads/main"
               ) do
          {:ok, commit_oid}
        end
      end)

    :ok = GitAgent.reference_create(agent, @checkpoint_ref, :oid, oid)
    {:ok, ref} = GitAgent.reference(agent, @checkpoint_ref)

    context
    |> Map.put(:agent, agent)
    |> Map.put(:commit_oid, oid)
    |> Map.put(:ref, ref)
  end
end
