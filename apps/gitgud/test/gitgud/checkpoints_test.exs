defmodule GitGud.CheckpointsTest do
  @moduledoc """
  Coverage for `GitGud.Checkpoints` — reading the AI coding-agent checkpoints the
  Entire CLI pushes as `refs/entire/checkpoints/<shard>/<id>`.
  """

  use GitGud.DataCase, async: false
  use GitGud.DataFactory

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  alias GitGud.Checkpoints
  alias GitGud.MetaDB
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User

  # `<shard>` is the last two characters of the 26-character ULID checkpoint id.
  @checkpoint_id "01K9TQ8ZP7X3F5M2WVJ4CNRB6D"
  @checkpoint_ref "refs/entire/checkpoints/6D/#{@checkpoint_id}"

  @legacy_id "01K9TQ8ZP7X3F5M2WVJ4CNRB6E"
  @legacy_branch "entire/checkpoints/v1"
  @legacy_dir "01/K9TQ8ZP7X3F5M2WVJ4CNRB6E"

  # A second, minimal checkpoint the tests write on demand.
  @other_checkpoint_id "01K9TQ8ZP7X3F5M2WVJ4CNRBZZ"
  @other_checkpoint_ref "refs/entire/checkpoints/ZZ/#{@other_checkpoint_id}"

  @first_line ~s({"type":"user","text":"Add a greeting to the README"})
  @second_line ~s({"type":"assistant","text":"Done \u2014 added it."})
  @transcript @first_line <> "\n" <> @second_line <> "\n"

  setup :create_user
  setup :create_repo

  describe "list/2" do
    setup :create_checkpoint

    test "returns the checkpoint summary", %{repo: repo} do
      assert {:ok, [checkpoint]} = Checkpoints.list(repo)

      assert checkpoint.id == @checkpoint_id
      assert checkpoint.ref == @checkpoint_ref
      assert checkpoint.source == :ref
      assert checkpoint.oid == hex(checkpoint_oid(repo))
      assert checkpoint.branch == "main"
      assert checkpoint.strategy == "manual-commit"
      assert checkpoint.checkpoints_count == 1
      assert checkpoint.files_touched == ["README.md", "SECOND.md"]
      assert checkpoint.session_count == 1
      assert checkpoint.token_usage == %{"input_tokens" => 158, "output_tokens" => 54}
      assert %DateTime{} = checkpoint.committed_at
    end

    test "caches the index in MetaDB", %{repo: repo} do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)

      assert %{watermark: watermark, checkpoints: checkpoints} = MetaDB.get_raw(index_key(repo))
      assert watermark == %{@checkpoint_ref => hex(checkpoint_oid(repo))}
      assert Map.has_key?(checkpoints, @checkpoint_id)
    end

    # The CLI records no `commit_sha` in `metadata.json`; the link is the
    # `Entire-Checkpoint:` trailer it writes into the user's own commit, which the
    # fixture puts on `main`.
    test "links the checkpoint to the commit carrying its trailer", %{
      repo: repo,
      main_oid: main_oid
    } do
      assert {:ok, [checkpoint]} = Checkpoints.list(repo)
      assert checkpoint.commit_sha == hex(main_oid)

      assert {:ok, %{commit_sha: commit_sha}} = Checkpoints.get(repo, @checkpoint_id)
      assert commit_sha == hex(main_oid)
    end

    # The trailer index is cached per branch *tip*, so the push that delivers the
    # trailer invalidates it, while a checkpoint push does not.
    test "caches the trailer index by branch tip", %{repo: repo, main_oid: main_oid} do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)

      assert %{oid: oid, links: links} = MetaDB.get_raw(links_key(repo, "main"))
      assert oid == hex(main_oid)
      assert links == %{String.downcase(@checkpoint_id) => hex(main_oid)}
    end

    test "leaves a checkpoint unlinked when its branch carries no trailer", %{repo: repo} do
      # A checkpoint captured on `topic`, whose tip is not a trailer commit.
      {:ok, moved_oid} =
        create_commit(repo, %{
          "metadata.json" =>
            Jason.encode!(%{
              "checkpoint_id" => @checkpoint_id,
              "branch" => "topic",
              "sessions" => []
            })
        })

      {:ok, agent} = GitRepo.get_agent(repo)
      :ok = GitAgent.reference_create(agent, "refs/heads/topic", :oid, moved_oid)
      :ok = GitAgent.reference_create(agent, @checkpoint_ref, :oid, moved_oid, force: true)

      assert {:ok, [%{commit_sha: nil}]} = Checkpoints.list(repo)
    end

    test "rebuilds the index once invalidated", %{repo: repo} do
      assert {:ok, [checkpoint]} = Checkpoints.list(repo)

      assert :ok = Checkpoints.invalidate(repo)
      assert MetaDB.get_raw(index_key(repo)) == nil

      assert {:ok, [rebuilt]} = Checkpoints.list(repo)
      assert rebuilt == checkpoint
      assert %{} = MetaDB.get_raw(index_key(repo))
    end

    test "rebuilds the index when the reference moves", %{repo: repo} do
      assert {:ok, [%{branch: "main"}]} = Checkpoints.list(repo)

      {:ok, moved_oid} =
        create_commit(repo, %{
          "metadata.json" =>
            Jason.encode!(%{
              "checkpoint_id" => @checkpoint_id,
              "branch" => "topic",
              "sessions" => []
            })
        })

      {:ok, agent} = GitRepo.get_agent(repo)
      :ok = GitAgent.reference_create(agent, @checkpoint_ref, :oid, moved_oid, force: true)

      assert {:ok, [%{branch: "topic"}]} = Checkpoints.list(repo)
    end

    test "skips an unreadable checkpoint", %{repo: repo} do
      {:ok, broken_oid} = create_commit(repo, %{"README.md" => "not a checkpoint\n"})
      {:ok, agent} = GitRepo.get_agent(repo)

      :ok =
        GitAgent.reference_create(
          agent,
          "refs/entire/checkpoints/ZZ/01K9TQ8ZP7X3F5M2WVJ4CNRBZZ",
          :oid,
          broken_oid
        )

      assert {:ok, [checkpoint]} = Checkpoints.list(repo)
      assert checkpoint.id == @checkpoint_id
    end

    test "returns nothing when disabled", %{repo: repo} do
      previous = Application.get_env(:gitgud, Checkpoints)
      Application.put_env(:gitgud, Checkpoints, enabled: false)
      on_exit(fn -> Application.put_env(:gitgud, Checkpoints, previous) end)

      refute Checkpoints.enabled?()
      assert {:ok, []} = Checkpoints.list(repo)
    end
  end

  describe "list/2 without checkpoints" do
    test "is empty for a repository without checkpoints", %{repo: repo} do
      assert {:ok, []} = Checkpoints.list(repo)
    end
  end

  describe "get/2" do
    setup :create_checkpoint

    test "returns the checkpoint with its raw metadata", %{repo: repo} do
      assert {:ok, checkpoint} = Checkpoints.get(repo, @checkpoint_id)
      assert checkpoint.id == @checkpoint_id
      assert checkpoint.metadata["cli_version"] == "0.11.5"
      assert checkpoint.metadata["checkpoint_id"] == @checkpoint_id
    end

    test "returns an error for an unknown id", %{repo: repo} do
      assert {:error, :not_found} = Checkpoints.get(repo, "01K9TQ8ZP7X3F5M2WVJ4CNRBZZ")
    end
  end

  describe "session/4" do
    setup :create_checkpoint

    test "returns the prompt and the transcript", %{repo: repo} do
      assert {:ok, session} = Checkpoints.session(repo, @checkpoint_id, 0)

      assert session.id == @checkpoint_id
      assert session.index == 0
      assert session.prompt == "Add a greeting to the README\n"
      assert session.transcript == [@first_line, @second_line]
      assert session.transcript_bytes == byte_size(@transcript)
      assert session.truncated == false
      assert session.metadata["agent"] == "opencode"
    end

    test "truncates on the last complete line", %{repo: repo} do
      max_bytes = byte_size(@first_line) + 8

      assert {:ok, session} = Checkpoints.session(repo, @checkpoint_id, 0, max_bytes: max_bytes)
      assert session.transcript == [@first_line]
      assert session.truncated == true
      assert session.transcript_bytes == byte_size(@transcript)
    end

    test "returns an error for an unknown session", %{repo: repo} do
      assert {:error, _reason} = Checkpoints.session(repo, @checkpoint_id, 9)
    end
  end

  describe "tasks/2" do
    setup :create_checkpoint

    test "returns the recorded subagent tasks", %{repo: repo} do
      assert {:ok, [task]} = Checkpoints.tasks(repo, @checkpoint_id)
      assert task.id == "task-1"
      assert task.path == "tasks/task-1/task.json"
      assert task.data["description"] == "Add a greeting"
    end

    test "is empty when the checkpoint has no tasks", %{repo: repo} do
      {:ok, oid} =
        create_commit(repo, %{
          "metadata.json" => Jason.encode!(%{"checkpoint_id" => @checkpoint_id})
        })

      {:ok, agent} = GitRepo.get_agent(repo)

      :ok =
        GitAgent.reference_create(
          agent,
          "refs/entire/checkpoints/ZZ/01K9TQ8ZP7X3F5M2WVJ4CNRBZZ",
          :oid,
          oid
        )

      assert {:ok, []} = Checkpoints.tasks(repo, "01K9TQ8ZP7X3F5M2WVJ4CNRBZZ")
    end
  end

  describe "prompts/2" do
    setup :create_checkpoint

    test "returns the session prompts in index order", %{repo: repo} do
      assert {:ok, [session]} = Checkpoints.prompts(repo, @checkpoint_id)
      assert session.index == 0
      assert session.prompt == "Add a greeting to the README\n"
    end

    test "reports a session without a prompt as nil", %{repo: repo} do
      {:ok, oid} =
        create_commit(repo, %{
          "metadata.json" => Jason.encode!(%{"checkpoint_id" => @other_checkpoint_id}),
          "0/metadata.json" => Jason.encode!(%{"session_id" => "sess-1"}),
          "1/prompt.txt" => "second\n"
        })

      {:ok, agent} = GitRepo.get_agent(repo)

      :ok =
        GitAgent.reference_create(
          agent,
          @other_checkpoint_ref,
          :oid,
          oid
        )

      assert {:ok, [first, second]} = Checkpoints.prompts(repo, @other_checkpoint_id)
      assert first == %{index: 0, prompt: nil}
      assert second == %{index: 1, prompt: "second\n"}
    end

    test "returns an error for an unknown id", %{repo: repo} do
      assert {:error, :not_found} = Checkpoints.prompts(repo, @other_checkpoint_id)
    end
  end

  describe "commit linkage" do
    setup :create_checkpoint

    test "resolves the trailer to the checkpoint id", %{repo: repo, main_oid: main_oid} do
      assert {:ok, [@checkpoint_id]} = Checkpoints.commit_ids(repo, hex(main_oid))
    end

    test "returns the checkpoint of a commit", %{repo: repo, main_oid: main_oid} do
      assert {:ok, [checkpoint]} = Checkpoints.for_commit(repo, hex(main_oid))
      assert checkpoint.id == @checkpoint_id
      assert checkpoint.metadata["cli_version"] == "0.11.5"
      assert checkpoint.commit_sha == hex(main_oid)
    end

    test "returns nothing for a commit without a trailer", %{repo: repo, checkpoint_oid: oid} do
      assert {:ok, []} = Checkpoints.commit_ids(repo, hex(oid))
      assert {:ok, []} = Checkpoints.for_commit(repo, hex(oid))
    end

    test "ignores merge commits", %{
      repo: repo,
      main_oid: main_oid,
      checkpoint_oid: checkpoint_oid
    } do
      {:ok, agent} = GitRepo.get_agent(repo)

      {:ok, merge_oid} =
        GitAgent.transaction(agent, fn agent ->
          with {:ok, tree_oid} <- write_tree(agent, %{"MERGE.md" => "merge\n"}) do
            GitAgent.commit_create(
              agent,
              signature(),
              signature(),
              "Merge branch 'topic'\n\nEntire-Checkpoint: #{@checkpoint_id}\n",
              tree_oid,
              [main_oid, checkpoint_oid]
            )
          end
        end)

      assert {:ok, []} = Checkpoints.commit_ids(repo, hex(merge_oid))
    end
  end

  describe "the legacy branch backend" do
    setup :create_legacy_checkpoint

    test "is listed alongside references", %{repo: repo} do
      assert {:ok, [checkpoint]} = Checkpoints.list(repo)
      assert checkpoint.id == @legacy_id
      assert checkpoint.source == :branch
      assert checkpoint.ref == "refs/heads/" <> @legacy_branch
    end

    test "is readable by id", %{repo: repo} do
      assert {:ok, checkpoint} = Checkpoints.get(repo, @legacy_id)
      assert checkpoint.metadata["checkpoint_id"] == @legacy_id
    end

    test "is kept in the index watermark", %{repo: repo, legacy_oid: legacy_oid} do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)

      assert %{watermark: watermark} = MetaDB.get_raw(index_key(repo))
      assert watermark["refs/heads/" <> @legacy_branch] == hex(legacy_oid)
    end
  end

  describe "checkpoint_ids/1" do
    test "reads repeated trailers" do
      message =
        "Fix things\n\nEntire-Checkpoint: #{@checkpoint_id}\nEntire-Checkpoint: #{@legacy_id}\n"

      assert Checkpoints.checkpoint_ids(message) == [@checkpoint_id, @legacy_id]
    end

    test "collapses repeats and tolerates casing" do
      message =
        "Fix things\n\nentire-checkpoint: #{@checkpoint_id}\nENTIRE-CHECKPOINT: #{@checkpoint_id}\n"

      assert Checkpoints.checkpoint_ids(message) == [@checkpoint_id]
    end

    test "is empty without a trailer" do
      assert Checkpoints.checkpoint_ids("Just a commit\n") == []
    end
  end

  describe "push invalidation" do
    setup :create_checkpoint

    test "drops the cached index when a push touches refs/entire/", %{
      repo: repo,
      checkpoint_oid: oid
    } do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)
      assert MetaDB.get_raw(index_key(repo))

      assert {:ok, _repo} = GitRepo.push(repo, [{:create, oid, @checkpoint_ref}])
      refute MetaDB.get_raw(index_key(repo))
    end

    test "keeps the cached index when a push only touches branches", %{
      repo: repo,
      checkpoint_oid: oid
    } do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)
      assert MetaDB.get_raw(index_key(repo))

      assert {:ok, _repo} = GitRepo.push(repo, [{:create, oid, "refs/heads/topic"}])
      assert MetaDB.get_raw(index_key(repo))
    end
  end

  describe "search/3" do
    setup :create_checkpoint

    test "matches a session prompt", %{repo: repo} do
      assert {:ok, [match]} = Checkpoints.search(repo, "greeting")

      assert match.checkpoint.id == @checkpoint_id
      assert match.matched == ["session 0 prompt"]
      assert match.score == 3
    end

    test "matches the summary fields", %{repo: repo} do
      assert {:ok, [match]} = Checkpoints.search(repo, @checkpoint_id)
      assert match.matched == ["id"]

      assert {:ok, [%{matched: ["branch"]}]} = Checkpoints.search(repo, "main")
      assert {:ok, [%{matched: ["strategy"]}]} = Checkpoints.search(repo, "manual-commit")
      assert {:ok, [%{matched: ["files_touched"]}]} = Checkpoints.search(repo, "second.md")

      assert {:ok, [%{matched: ["files_touched", "session 0 prompt"]}]} =
               Checkpoints.search(repo, "README")
    end

    test "requires every term to match", %{repo: repo} do
      assert {:ok, [match]} = Checkpoints.search(repo, "greeting SECOND")
      assert match.matched == ["files_touched", "session 0 prompt"]
      assert match.score == 6

      assert {:ok, []} = Checkpoints.search(repo, "greeting nonexistent")
    end

    test "drops stop words and single characters", %{repo: repo} do
      assert {:ok, []} = Checkpoints.search(repo, "a the to")
      assert {:ok, []} = Checkpoints.search(repo, "")
      assert {:ok, [%{matched: ["session 0 prompt"]}]} = Checkpoints.search(repo, "the greeting")
    end

    test "does not index the agent transcripts", %{repo: repo} do
      # "Done" only ever appears in `0/full.jsonl`.
      assert {:ok, []} = Checkpoints.search(repo, "done")
    end

    test "ranks the checkpoint with more matched fields first", %{repo: repo} do
      create_nested_checkpoint(repo, %{
        "branch" => "readme-topic",
        "files_touched" => ["docs/notes.md"]
      })

      assert {:ok, [first, second]} = Checkpoints.search(repo, "readme")
      assert first.checkpoint.id == @checkpoint_id
      assert first.matched == ["files_touched", "session 0 prompt"]
      assert second.checkpoint.id == @other_checkpoint_id
      assert second.matched == ["branch"]
    end

    test "caches the term index in MetaDB", %{repo: repo} do
      assert {:ok, [_match]} = Checkpoints.search(repo, "greeting")

      assert %{terms: terms} = MetaDB.get_raw(index_key(repo))
      assert terms["greeting"] == [{@checkpoint_id, 0}]
      assert terms["add"] == [{@checkpoint_id, 0}]
      # Stop words and single characters are not indexed.
      assert terms["the"] == nil
      assert terms["a"] == nil
      refute Map.has_key?(terms, "done")
    end

    test "searches again after the index is invalidated", %{repo: repo} do
      assert {:ok, [_match]} = Checkpoints.search(repo, "greeting")

      assert :ok = Checkpoints.invalidate(repo)
      assert {:ok, [%{checkpoint: %{id: @checkpoint_id}}]} = Checkpoints.search(repo, "greeting")
    end

    test "returns nothing when disabled", %{repo: repo} do
      previous = Application.get_env(:gitgud, Checkpoints)
      Application.put_env(:gitgud, Checkpoints, enabled: false)
      on_exit(fn -> Application.put_env(:gitgud, Checkpoints, previous) end)

      assert {:ok, []} = Checkpoints.search(repo, "greeting")
    end
  end

  describe "search/3 without checkpoints" do
    test "is empty for a repository without checkpoints", %{repo: repo} do
      assert {:ok, []} = Checkpoints.search(repo, "greeting")
    end
  end

  describe "provenance/3" do
    setup :create_checkpoint

    test "matches a touched file", %{repo: repo} do
      assert {:ok, [match]} = Checkpoints.provenance(repo, "README.md")

      assert match.checkpoint.id == @checkpoint_id
      assert match.matched == ["README.md"]
      assert match.score == 1
    end

    test "matches a directory, but not a partial file name", %{repo: repo} do
      create_nested_checkpoint(repo, %{"files_touched" => ["lib/gitgud/repo.ex"]})

      assert {:ok, [%{matched: ["lib/gitgud/repo.ex"]}]} = Checkpoints.provenance(repo, "lib")

      assert {:ok, [%{matched: ["lib/gitgud/repo.ex"]}]} =
               Checkpoints.provenance(repo, "lib/gitgud")

      assert {:ok, [%{matched: ["lib/gitgud/repo.ex"]}]} =
               Checkpoints.provenance(repo, "lib/gitgud/repo.ex")

      assert {:ok, []} = Checkpoints.provenance(repo, "lib/gitgud/repo")
      assert {:ok, []} = Checkpoints.provenance(repo, "nope.md")
    end

    test "normalizes the path", %{repo: repo} do
      assert {:ok, [%{matched: ["README.md"]}]} = Checkpoints.provenance(repo, " ./README.md/ ")
    end

    test "returns the checkpoints newest first", %{repo: repo} do
      create_nested_checkpoint(repo, %{"files_touched" => ["README.md"]})

      assert {:ok, matches} = Checkpoints.provenance(repo, "README.md")
      assert Enum.map(matches, & &1.checkpoint.id) == [@other_checkpoint_id, @checkpoint_id]
    end

    test "returns nothing when disabled", %{repo: repo} do
      previous = Application.get_env(:gitgud, Checkpoints)
      Application.put_env(:gitgud, Checkpoints, enabled: false)
      on_exit(fn -> Application.put_env(:gitgud, Checkpoints, previous) end)

      assert {:ok, []} = Checkpoints.provenance(repo, "README.md")
    end
  end

  describe "retention" do
    setup :create_checkpoint

    test "drops a deleted checkpoint from the list", %{repo: repo, agent: agent} do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)

      :ok = GitAgent.reference_delete(agent, @checkpoint_ref)

      assert {:ok, []} = Checkpoints.list(repo)
    end

    test "rebuilds the index without a deleted checkpoint", %{repo: repo, agent: agent} do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)
      assert %{watermark: watermark} = MetaDB.get_raw(index_key(repo))
      assert Map.has_key?(watermark, @checkpoint_ref)

      :ok = GitAgent.reference_delete(agent, @checkpoint_ref)
      assert {:ok, []} = Checkpoints.list(repo)

      assert %{watermark: watermark, checkpoints: checkpoints} = MetaDB.get_raw(index_key(repo))
      refute Map.has_key?(watermark, @checkpoint_ref)
      assert checkpoints == %{}
    end

    test "reports a deleted checkpoint as not found", %{repo: repo, agent: agent} do
      assert {:ok, _checkpoint} = Checkpoints.get(repo, @checkpoint_id)

      :ok = GitAgent.reference_delete(agent, @checkpoint_ref)

      assert {:error, :not_found} = Checkpoints.get(repo, @checkpoint_id)
      assert {:error, :not_found} = Checkpoints.session(repo, @checkpoint_id, 0)
    end

    test "drops the cached index when a push deletes a checkpoint ref", %{
      repo: repo,
      checkpoint_oid: oid
    } do
      assert {:ok, [_checkpoint]} = Checkpoints.list(repo)
      assert MetaDB.get_raw(index_key(repo))

      assert {:ok, _repo} = GitRepo.push(repo, [{:delete, oid, @checkpoint_ref}])
      refute MetaDB.get_raw(index_key(repo))
    end
  end

  describe "short id resolution" do
    setup :create_checkpoint

    test "resolves an unambiguous prefix", %{repo: repo} do
      prefix = String.slice(@checkpoint_id, 0, 7)

      assert {:ok, %{id: @checkpoint_id}} = Checkpoints.get(repo, prefix)
      assert {:ok, %{id: @checkpoint_id}} = Checkpoints.session(repo, prefix, 0)
      assert {:ok, [%{index: 0}]} = Checkpoints.prompts(repo, prefix)
      assert {:ok, [_task]} = Checkpoints.tasks(repo, prefix)
    end

    test "resolves a prefix case-insensitively", %{repo: repo} do
      prefix = @checkpoint_id |> String.slice(0, 7) |> String.downcase()

      assert {:ok, %{id: @checkpoint_id}} = Checkpoints.get(repo, prefix)
    end

    test "still resolves a full id", %{repo: repo} do
      assert {:ok, %{id: @checkpoint_id}} = Checkpoints.get(repo, @checkpoint_id)
    end

    test "reports a prefix that matches more than one checkpoint as ambiguous", %{repo: repo} do
      create_nested_checkpoint(repo, %{})

      assert {:error, :ambiguous} = Checkpoints.get(repo, String.slice(@checkpoint_id, 0, 22))
    end

    test "does not expand a prefix shorter than the minimum", %{repo: repo} do
      create_nested_checkpoint(repo, %{})

      assert {:error, :not_found} = Checkpoints.get(repo, String.slice(@checkpoint_id, 0, 3))
    end
  end

  describe "storage/1" do
    setup :create_checkpoint

    test "counts the checkpoints and the bytes they weigh", %{repo: repo} do
      assert {:ok, %{count: 1, bytes: bytes, truncated?: false}} = Checkpoints.storage(repo)

      expected = checkpoint_files() |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
      assert bytes == expected
    end

    test "counts a blob two checkpoints share only once", %{repo: repo, agent: agent} do
      assert {:ok, %{bytes: single}} = Checkpoints.storage(repo)

      metadata = Jason.encode!(%{"checkpoint_id" => @other_checkpoint_id, "sessions" => []})

      {:ok, oid} =
        create_commit(repo, %{
          "metadata.json" => metadata,
          # The very same prompt blob the first checkpoint already carries.
          "0/prompt.txt" => "Add a greeting to the README\n"
        })

      :ok = GitAgent.reference_create(agent, @other_checkpoint_ref, :oid, oid)

      assert {:ok, %{count: 2, bytes: bytes}} = Checkpoints.storage(repo)
      assert bytes == single + byte_size(metadata)
    end
  end

  describe "storage/1 without checkpoints" do
    test "is empty for a repository without checkpoints", %{repo: repo} do
      assert {:ok, %{count: 0, bytes: 0, truncated?: false}} = Checkpoints.storage(repo)
    end

    test "is empty when checkpoint reading is disabled", %{repo: repo} do
      without_checkpoints(fn ->
        assert {:ok, %{count: 0, bytes: 0, truncated?: false}} = Checkpoints.storage(repo)
      end)
    end
  end

  describe "storage/1 with the legacy branch" do
    setup :create_legacy_checkpoint

    test "measures a legacy branch checkpoint", %{repo: repo} do
      assert {:ok, %{count: 1, bytes: bytes, truncated?: false}} = Checkpoints.storage(repo)
      assert bytes > 0
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
      Checkpoints.invalidate(repo)
    end)

    Map.put(context, :repo, repo)
  end

  defp create_checkpoint(%{repo: repo} = context) do
    {:ok, agent} = GitRepo.get_agent(repo)

    {:ok, checkpoint_oid} =
      GitAgent.transaction(agent, fn agent ->
        with {:ok, tree_oid} <- write_tree(agent, checkpoint_files()) do
          GitAgent.commit_create(
            agent,
            signature(),
            signature(),
            "Checkpoint #{@checkpoint_id}\n",
            tree_oid,
            []
          )
        end
      end)

    :ok = GitAgent.reference_create(agent, @checkpoint_ref, :oid, checkpoint_oid)

    # The user's own commit, carrying the trailer that links it to the checkpoint.
    {:ok, main_oid} =
      GitAgent.transaction(agent, fn agent ->
        with {:ok, tree_oid} <- write_tree(agent, %{"README.md" => "hello world\n"}) do
          GitAgent.commit_create(
            agent,
            signature(),
            signature(),
            "Add a greeting\n\nEntire-Checkpoint: #{@checkpoint_id}\n",
            tree_oid,
            [],
            update_ref: "refs/heads/main"
          )
        end
      end)

    context
    |> Map.put(:agent, agent)
    |> Map.put(:checkpoint_oid, checkpoint_oid)
    |> Map.put(:main_oid, main_oid)
  end

  defp create_legacy_checkpoint(%{repo: repo} = context) do
    {:ok, agent} = GitRepo.get_agent(repo)

    {:ok, legacy_oid} =
      create_commit(repo, %{
        "#{@legacy_dir}/metadata.json" =>
          Jason.encode!(%{"checkpoint_id" => @legacy_id, "branch" => "main", "sessions" => []}),
        "#{@legacy_dir}/0/prompt.txt" => "Legacy prompt\n"
      })

    :ok = GitAgent.reference_create(agent, "refs/heads/" <> @legacy_branch, :oid, legacy_oid)

    context
    |> Map.put(:agent, agent)
    |> Map.put(:legacy_oid, legacy_oid)
  end

  defp checkpoint_files do
    %{
      "metadata.json" =>
        Jason.encode!(%{
          "cli_version" => "0.11.5",
          "checkpoint_id" => @checkpoint_id,
          "strategy" => "manual-commit",
          "branch" => "main",
          "checkpoints_count" => 1,
          "files_touched" => ["README.md", "SECOND.md"],
          "sessions" => [
            %{
              "metadata" => "/0/metadata.json",
              "transcript" => "/0/full.jsonl",
              "compact_transcript" => "/0/transcript.jsonl",
              "content_hash" => "/0/content_hash.txt",
              "prompt" => "/0/prompt.txt"
            }
          ],
          "token_usage" => %{"input_tokens" => 158, "output_tokens" => 54}
        }),
      "0/metadata.json" => Jason.encode!(%{"session_id" => "sess-1", "agent" => "opencode"}),
      "0/prompt.txt" => "Add a greeting to the README\n",
      "0/content_hash.txt" => sha256(@transcript),
      "0/full.jsonl" => @transcript,
      "0/transcript.jsonl" => @first_line <> "\n",
      "tasks/task-1/task.json" =>
        Jason.encode!(%{"description" => "Add a greeting", "status" => "completed"}),
      "tasks/task-1/agent-sub-1.jsonl" => ~s({"type":"text","text":"ok"}) <> "\n"
    }
  end

  # A second, minimal checkpoint whose `metadata.json` carries the given fields.
  defp create_nested_checkpoint(repo, fields) do
    {:ok, oid} =
      create_commit(repo, %{
        "metadata.json" =>
          Jason.encode!(
            Map.merge(%{"checkpoint_id" => @other_checkpoint_id, "sessions" => []}, fields)
          )
      })

    {:ok, agent} = GitRepo.get_agent(repo)
    :ok = GitAgent.reference_create(agent, @other_checkpoint_ref, :oid, oid)
    oid
  end

  defp create_commit(repo, files) do
    {:ok, agent} = GitRepo.get_agent(repo)

    GitAgent.transaction(agent, fn agent ->
      with {:ok, tree_oid} <- write_tree(agent, files) do
        GitAgent.commit_create(agent, signature(), signature(), "Commit\n", tree_oid, [])
      end
    end)
  end

  defp write_tree(agent, files) do
    with {:ok, odb} <- GitAgent.odb(agent),
         {:ok, index} <- GitAgent.index(agent),
         {:ok, index} <- add_files(agent, odb, index, Enum.sort(files)) do
      GitAgent.index_write_tree(agent, index)
    end
  end

  defp add_files(_agent, _odb, index, []), do: {:ok, index}

  defp add_files(agent, odb, index, [{path, content} | files]) do
    with {:ok, oid} <- GitAgent.odb_write(agent, odb, content, :blob),
         :ok <- GitAgent.index_add(agent, index, oid, path, byte_size(content), 0o100644) do
      add_files(agent, odb, index, files)
    end
  end

  defp signature do
    %{name: "Entire", email: "agent@entire.io", timestamp: DateTime.now!("Etc/UTC")}
  end

  defp sha256(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp hex(oid), do: Base.encode16(oid, case: :lower)

  defp links_key(%Repo{owner_login: owner_login, name: name}, branch),
    do: {:checkpoints_links, owner_login, name, branch}

  defp index_key(%Repo{owner_login: owner_login, name: name}),
    do: {:checkpoints, owner_login, name}

  defp without_checkpoints(fun) do
    previous = Application.get_env(:gitgud, Checkpoints)
    Application.put_env(:gitgud, Checkpoints, enabled: false)
    on_exit(fn -> Application.put_env(:gitgud, Checkpoints, previous) end)
    fun.()
  end

  defp checkpoint_oid(repo) do
    {:ok, agent} = GitRepo.get_agent(repo)
    {:ok, ref} = GitAgent.reference(agent, @checkpoint_ref)
    ref.oid
  end
end
