defmodule GitGud.CheckpointsTransportTest do
  @moduledoc """
  The checkpoint namespace in the Git transports.

  While checkpoint reading is enabled, `refs/entire/*` is advertised as usual; when
  it is disabled the namespace is hidden from the advertisement instead of leaking
  checkpoint ids and counts to every clone and fetch
  (`guides/Sessions and Checkpoints.md` §7, risk 2).
  """

  use GitGud.DataCase, async: false
  use GitGud.DataFactory

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo
  alias GitRekt.WireProtocol
  alias GitRekt.WireProtocol.ReceivePack

  alias GitGud.Checkpoints
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.SmartHTTPBackendRouter
  alias GitGud.User

  # A realistic git-refs checkpoint ref: `<shard>` is the last two characters of
  # the 26-character ULID checkpoint id.
  @checkpoint_ref "refs/entire/checkpoints/6D/01K9TQ8ZP7X3F5M2WVJ4CNRB6D"

  setup :create_user
  setup :create_repo
  setup :create_checkpoint_ref

  describe "hidden_reference_prefixes/0" do
    test "is empty while checkpoints are enabled" do
      assert Checkpoints.enabled?()
      assert Checkpoints.hidden_reference_prefixes() == []
    end

    test "hides the checkpoint namespace when checkpoints are disabled" do
      without_checkpoints(fn ->
        assert Checkpoints.hidden_reference_prefixes() == [Checkpoints.ref_prefix()]
      end)
    end
  end

  describe "reference discovery" do
    test "advertises the checkpoint ref by default", %{agent: agent} do
      assert discovery(agent) =~ @checkpoint_ref
    end

    test "omits it when the namespace is hidden", %{agent: agent} do
      lines = discovery(agent, [Checkpoints.ref_prefix()])

      refute lines =~ @checkpoint_ref
      assert lines =~ "refs/heads/main"
      assert lines =~ "HEAD"
    end
  end

  describe "the Git transports" do
    test "carry the exclusions into both services", %{agent: agent} do
      prefixes = Checkpoints.hidden_reference_prefixes()

      upload_pack = WireProtocol.new(agent, "git-upload-pack", hide_references: prefixes)
      receive_pack = WireProtocol.new(agent, "git-receive-pack", hide_references: prefixes)

      assert upload_pack.hide_references == prefixes
      assert receive_pack.hide_references == prefixes
    end

    test "answer the Smart HTTP `info/refs` request with the checkpoint ref", %{
      repo: repo,
      user: user
    } do
      assert info_refs(repo, user) =~ @checkpoint_ref
    end

    test "answer it without the checkpoint ref when checkpoints are disabled", %{
      repo: repo,
      user: user
    } do
      without_checkpoints(fn ->
        refute info_refs(repo, user) =~ @checkpoint_ref
      end)
    end
  end

  describe "reference_policy/0" do
    test "accepts branches, tags and a well-formed checkpoint ref" do
      policy = Checkpoints.reference_policy()

      assert policy.("refs/heads/main") == :ok
      assert policy.("refs/tags/v1") == :ok
      assert policy.(@checkpoint_ref) == :ok
    end

    test "refuses a malformed checkpoint ref" do
      policy = Checkpoints.reference_policy()

      assert {:error, _reason} = policy.("refs/entire/checkpoints/6D/short")
      assert {:error, _reason} = policy.("refs/entire/checkpoints/6D/02/extra")
      assert {:error, _reason} = policy.("refs/entire/whole")
    end

    test "refuses the checkpoint namespace when checkpoint reading is disabled" do
      without_checkpoints(fn ->
        policy = Checkpoints.reference_policy()

        assert {:error, "checkpoint-reading-disabled"} = policy.(@checkpoint_ref)
        assert policy.("refs/heads/main") == :ok
      end)
    end
  end

  describe "the push guard" do
    test "reports a refused checkpoint ref instead of writing it", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      bad = "refs/entire/checkpoints/6D/short"
      output = push(agent, repo, [{:update, oid, oid, bad}])

      assert "ng #{bad} invalid-checkpoint-reference" in output
      refute "ok #{bad}" in output
      assert "unpack ok" in output
      assert {:error, _reason} = GitAgent.reference(agent, bad)
    end

    test "reports a reference name Git itself forbids", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      bad = "refs/heads/bad..name"
      output = push(agent, repo, [{:create, oid, bad}])

      assert "ng #{bad} invalid-reference-name" in output
      assert {:error, _reason} = GitAgent.reference(agent, bad)
    end

    test "applies an accepted reference and reports it ok", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      output = push(agent, repo, [{:update, oid, oid, "refs/heads/topic"}])

      assert "ok refs/heads/topic" in output
      assert {:ok, _ref} = GitAgent.reference(agent, "refs/heads/topic")
    end

    test "refuses the checkpoint namespace when checkpoint reading is disabled", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      without_checkpoints(fn ->
        output = push(agent, repo, [{:update, oid, oid, @checkpoint_ref}])

        assert "ng #{@checkpoint_ref} checkpoint-reading-disabled" in output
        assert {:ok, _ref} = GitAgent.reference(agent, @checkpoint_ref)
      end)
    end

    test "still allows deleting a checkpoint ref while checkpoint reading is disabled", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      without_checkpoints(fn ->
        output = push(agent, repo, [{:delete, oid, @checkpoint_ref}])

        assert "ok #{@checkpoint_ref}" in output
        assert {:error, _reason} = GitAgent.reference(agent, @checkpoint_ref)
      end)
    end
  end

  #
  # Helpers
  #

  defp discovery(agent, hidden \\ []) do
    WireProtocol.reference_discovery(agent, "git-upload-pack", [], hide_references: hidden)
    |> Enum.reject(&(&1 == :flush))
    |> Enum.join()
  end

  defp info_refs(repo, user) do
    conn = conn(:get, "/#{repo.owner_login}/#{repo.name}.git/info/refs?service=git-upload-pack")

    conn =
      put_req_header(conn, "authorization", "Basic " <> Base.encode64("#{user.login}:qwertz"))

    conn = SmartHTTPBackendRouter.call(conn, [])

    assert conn.status == 200
    conn.resp_body
  end

  defp without_checkpoints(fun) do
    previous = Application.get_env(:gitgud, Checkpoints)
    Application.put_env(:gitgud, Checkpoints, enabled: false)
    on_exit(fn -> Application.put_env(:gitgud, Checkpoints, previous) end)
    fun.()
  end

  # Drives `GitRekt.WireProtocol.ReceivePack` straight to its `:done` state with a
  # fabricated command list, so the policy is exercised without a real pack.
  defp push(agent, repo, cmds) do
    handle =
      WireProtocol.new(agent, "git-receive-pack",
        repo: repo,
        caps: ["report-status"],
        reference_policy: Checkpoints.reference_policy()
      )

    {_handle, _lines, output} = ReceivePack.next(%{handle | state: :done, cmds: cmds}, [])
    List.flatten(output)
  end

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
      Checkpoints.invalidate(repo)
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

    context
    |> Map.put(:agent, agent)
    |> Map.put(:commit_oid, oid)
  end
end
