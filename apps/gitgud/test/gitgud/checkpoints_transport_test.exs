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

  # The all-zero object id git sends as the *new* oid of a deletion command.
  @null_oid String.duplicate("0", 40)

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

  describe "a delete-only push" do
    # A push that only removes references carries **no packfile**: `git send-pack`
    # sets `need_pack_data = 0` (a deletion needs no objects) and closes the stream
    # right after the command list. The service used to wait in `:pack` for a pack
    # that never arrived, so `git push --delete` — and `entire checkpoint delete` —
    # hung, leaving the reference in place. It must reach `:done` and answer with
    # the status report in the very same call.
    test "reaches :done and reports the status without a packfile", %{
      agent: agent,
      repo: repo,
      commit_oid: oid
    } do
      service = %{receive_pack(agent, repo) | state: :update_req}
      request = update_request([delete_cmd(oid, @checkpoint_ref)])

      assert {:halt, service, output} = WireProtocol.next(service, request)
      assert service.state == :done

      output = IO.iodata_to_binary(output)
      assert output =~ "unpack ok"
      assert output =~ "ok #{@checkpoint_ref}"
      assert {:error, _reason} = GitAgent.reference(agent, @checkpoint_ref)
    end

    # The same request through the whole state machine, as the SSH server and the
    # Smart HTTP backend drive it.
    test "reports the status from a fresh service", %{agent: agent, repo: repo, commit_oid: oid} do
      service =
        WireProtocol.new(agent, "git-receive-pack",
          repo: repo,
          reference_policy: Checkpoints.reference_policy()
        )

      {service, _advertisement} = WireProtocol.next(service, :discovery)

      {:halt, service, output} =
        WireProtocol.next(service, update_request([delete_cmd(oid, @checkpoint_ref)]))

      assert service.state == :done
      assert IO.iodata_to_binary(output) =~ "ok #{@checkpoint_ref}"
    end
  end

  #
  # Helpers
  #

  # A `git-receive-pack` handle configured the way both transports configure it.
  defp receive_pack(agent, repo) do
    WireProtocol.new(agent, "git-receive-pack",
      repo: repo,
      caps: ["report-status"],
      reference_policy: Checkpoints.reference_policy()
    )
  end

  # A `delete` command line, as `git send-pack` writes it. The old oid goes on the
  # wire as lowercase hex.
  defp delete_cmd(old_oid, name),
    do: "#{Base.encode16(old_oid, case: :lower)} #{@null_oid} #{name}"

  # A `git-receive-pack` request body: the command lines — the first one carrying
  # the capabilities — then a flush packet, and *nothing else* for a delete-only
  # push, which is the whole point.
  defp update_request([first | rest]) do
    ([first <> "\0report-status" | rest] ++ [:flush])
    |> WireProtocol.encode()
    |> IO.iodata_to_binary()
  end

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
    handle = %{receive_pack(agent, repo) | state: :done, cmds: cmds}

    {_handle, _lines, output} = ReceivePack.next(handle, [])
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
