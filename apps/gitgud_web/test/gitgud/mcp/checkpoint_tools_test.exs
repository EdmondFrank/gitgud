defmodule GitGud.MCP.CheckpointToolsTest do
  @moduledoc """
  Unit tests for the `GitGud.MCP.Tools.{List,Get,Search}Checkpoints` and
  `GitGud.MCP.Tools.CheckpointProvenance` tools (see
  `guides/Sessions and Checkpoints.md`, Phases 3 and 4).

  Tools are pure functions of `(params, frame)`; the authenticated user is
  supplied through `frame.assigns[:current_user]`, mirroring how Anubis merges
  `Plug.Conn.assigns` into the tool frame at runtime.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias Anubis.Server.Frame

  alias GitGud.Checkpoints
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User
  alias GitGud.Web.CheckpointFactory

  alias GitGud.MCP.Tools.CheckpointProvenance
  alias GitGud.MCP.Tools.GetCheckpoint
  alias GitGud.MCP.Tools.ListCheckpoints
  alias GitGud.MCP.Tools.SearchCheckpoints

  @unknown_id "01K9TQ8ZP7X3F5M2WVJ4CNRBZZ"

  setup do
    %{user: User.create!(factory(:user))}
  end

  describe "list_checkpoints" do
    test "lists the repository's checkpoints", %{user: user} do
      {repo, main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => data} = invoke(ListCheckpoints, params(repo), user)

      assert data["total_count"] == 1
      assert [checkpoint] = data["checkpoints"]
      assert checkpoint["id"] == CheckpointFactory.checkpoint_id()
      assert checkpoint["commit_sha"] == main_sha
      assert checkpoint["source"] == "ref"
      assert checkpoint["branch"] == "main"
      assert checkpoint["session_count"] == 1
      assert checkpoint["files_touched"] == ["README.md", "SECOND.md"]
      assert checkpoint["token_usage"] == %{"input_tokens" => 158, "output_tokens" => 54}
      refute Map.has_key?(checkpoint, "metadata")
    end

    test "returns an empty list for a repository without checkpoints", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => true, "data" => %{"checkpoints" => [], "total_count" => 0}} =
               invoke(ListCheckpoints, params(repo), user)
    end

    test "skips checkpoints with offset", %{user: user} do
      repo = create_repo(user)
      create_checkpoint(repo)

      assert %{"ok" => true, "data" => %{"checkpoints" => [], "total_count" => 1}} =
               invoke(ListCheckpoints, Map.put(params(repo), :offset, 1), user)
    end

    test "reports a private repository of another user as not_found", %{user: user} do
      other = User.create!(factory(:user))
      repo = create_repo(other, %{public: false})

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(ListCheckpoints, params(repo), user)
    end
  end

  describe "get_checkpoint" do
    test "returns the checkpoint metadata and its tasks", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => data} = invoke(GetCheckpoint, get_params(repo), user)

      assert data["id"] == CheckpointFactory.checkpoint_id()
      assert data["session_count"] == 1
      assert data["metadata"]["strategy"] == "manual-commit"
      assert data["metadata"]["files_touched"] == ["README.md", "SECOND.md"]

      assert [task] = data["tasks"]
      assert task["id"] == "task-1"
      assert task["task"]["status"] == "completed"

      refute Map.has_key?(data, "session")
    end

    test "includes a single session's prompt and transcript", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => %{"session" => session}} =
               invoke(GetCheckpoint, Map.put(get_params(repo), :session, 0), user)

      assert session["index"] == 0
      assert session["prompt"] == "Add a greeting to the README\n"
      assert session["metadata"]["agent"] == "opencode"
      assert session["truncated"] == false
      assert session["transcript_bytes"] == byte_size(CheckpointFactory.full_transcript())

      assert length(session["transcript"]) == CheckpointFactory.transcript_lines()
    end

    test "reports an unknown checkpoint as not_found", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(GetCheckpoint, Map.put(params(repo), :id, @unknown_id), user)
    end

    test "reports an unknown session index as an error", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => false} =
               invoke(GetCheckpoint, Map.put(get_params(repo), :session, 42), user)
    end
  end

  describe "search_checkpoints" do
    test "matches a session prompt", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => data} =
               invoke(SearchCheckpoints, search_params(repo, "greeting"), user)

      assert data["total_count"] == 1
      assert [match] = data["matches"]
      assert match["id"] == CheckpointFactory.checkpoint_id()
      assert "session 0 prompt" in match["matched"]
    end

    test "matches the branch, the strategy and a touched file", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => %{"matches" => [by_file]}} =
               invoke(SearchCheckpoints, search_params(repo, "SECOND.md"), user)

      assert by_file["matched"] == ["files_touched"]

      assert %{"ok" => true, "data" => %{"matches" => [by_branch]}} =
               invoke(SearchCheckpoints, search_params(repo, "MAIN"), user)

      assert "branch" in by_branch["matched"]

      assert %{"ok" => true, "data" => %{"matches" => [by_strategy]}} =
               invoke(SearchCheckpoints, search_params(repo, "manual-commit"), user)

      assert "strategy" in by_strategy["matched"]
    end

    test "requires every term to match", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => %{"matches" => [match]}} =
               invoke(SearchCheckpoints, search_params(repo, "greeting SECOND"), user)

      assert match["matched"] == ["files_touched", "session 0 prompt"]
      assert match["score"] == 6

      assert %{"ok" => true, "data" => %{"matches" => []}} =
               invoke(SearchCheckpoints, search_params(repo, "greeting nonexistent"), user)
    end

    test "only scans the transcripts when asked to", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => %{"matches" => []}} =
               invoke(SearchCheckpoints, search_params(repo, "line 42"), user)

      assert %{"ok" => true, "data" => %{"matches" => [match]}} =
               invoke(
                 SearchCheckpoints,
                 Map.put(search_params(repo, "line 42"), :include_transcripts, true),
                 user
               )

      assert "session 0 transcript" in match["matched"]
    end

    test "rejects an empty query", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => false, "error" => "empty_query"} =
               invoke(SearchCheckpoints, search_params(repo, "   "), user)
    end
  end

  describe "checkpoint_provenance" do
    test "maps a file back to the checkpoints that touched it", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => data} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "README.md"), user)

      assert data["total_count"] == 1
      assert [match] = data["matches"]
      assert match["id"] == CheckpointFactory.checkpoint_id()
      assert match["matched"] == ["README.md"]
      assert match["score"] == 1
    end

    test "accepts a directory", %{user: user} do
      repo = create_repo(user)
      create_checkpoint(repo, files_touched: ["lib/gitgud/repo.ex", "README.md"])

      assert %{"ok" => true, "data" => %{"matches" => [match]}} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "lib/gitgud"), user)

      assert match["matched"] == ["lib/gitgud/repo.ex"]

      assert %{"ok" => true, "data" => %{"matches" => []}} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "lib/gitgud/repo"), user)
    end

    test "reports an unknown path as empty", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => true, "data" => %{"matches" => [], "total_count" => 0}} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "nope.md"), user)
    end

    test "rejects an empty path", %{user: user} do
      {repo, _main_sha} = create_repo_with_checkpoint(user)

      assert %{"ok" => false, "error" => "empty_path"} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "  "), user)
    end

    test "reports a private repository of another user as not_found", %{user: user} do
      other = User.create!(factory(:user))
      repo = create_repo(other, %{public: false})

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(CheckpointProvenance, Map.put(params(repo), :path, "README.md"), user)
    end
  end

  #
  # Helpers
  #

  defp invoke(module, params, user) do
    frame = Frame.new(%{current_user: user})
    {:reply, response, _frame} = module.execute(params, frame)
    [%{"text" => text} | _] = response.content
    Jason.decode!(text)
  end

  defp params(repo), do: %{owner: repo.owner_login, name: repo.name}

  defp get_params(repo), do: Map.put(params(repo), :id, CheckpointFactory.checkpoint_id())

  defp search_params(repo, query), do: Map.put(params(repo), :query, query)

  defp create_repo(user, overrides \\ %{}) do
    repo = Repo.create!(user, Map.merge(factory(:repo), overrides))

    on_exit(fn ->
      File.rm_rf(RepoStorage.workdir(repo))
      Checkpoints.invalidate(repo)
    end)

    repo
  end

  defp create_checkpoint(repo, opts \\ []) do
    %{main_sha: main_sha} = CheckpointFactory.write!(repo, opts)
    main_sha
  end

  defp create_repo_with_checkpoint(user) do
    repo = create_repo(user)
    {repo, create_checkpoint(repo)}
  end
end
