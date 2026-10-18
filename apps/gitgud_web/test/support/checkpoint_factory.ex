defmodule GitGud.Web.CheckpointFactory do
  @moduledoc """
  Test fixture that writes an Entire-CLI shaped checkpoint into a repository's own
  object store: a two-commit history (the second commit carrying the
  `Entire-Checkpoint:` trailer), the checkpoint tree root, and the
  `refs/entire/checkpoints/<shard>/<id>` reference pointing at it.

  Everything is built in memory with `GitRekt.GitAgent` — no network, no
  checked-in binaries. Shared by the Phase 2 LiveView tests and the Phase 3
  GraphQL/MCP tests; see `guides/Sessions and Checkpoints.md`.
  """

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  # `<shard>` is the last two characters of the 26-character ULID checkpoint id.
  @checkpoint_id "01K9TQ8ZP7X3F5M2WVJ4CNRB6D"
  @checkpoint_ref "refs/entire/checkpoints/6D/#{@checkpoint_id}"

  @files_touched ["README.md", "SECOND.md"]

  @first_line ~s({"type":"user","text":"Add a greeting to the README"})
  @second_line ~s({"type":"assistant","text":"Done — added it."})

  def checkpoint_id, do: @checkpoint_id
  def checkpoint_ref, do: @checkpoint_ref
  def first_line, do: @first_line
  def second_line, do: @second_line

  @doc """
  Writes the fixture into `repo`.

  Returns `%{main_sha: hex, checkpoint_oid: oid}` — the commit carrying the
  trailer and the checkpoint commit the reference points at. `files_touched:`
  overrides the files the checkpoint records as having touched.
  """
  @spec write!(GitGud.Repo.t(), keyword) :: %{main_sha: binary, checkpoint_oid: binary}
  def write!(repo, opts \\ []) do
    {:ok, agent} = GitRepo.get_agent(repo)
    base_oid = commit!(agent, %{"README.md" => "hello\n"}, "Initial commit\n", [])

    main_oid =
      commit!(
        agent,
        %{"README.md" => "hello world\n", "SECOND.md" => "second\n"},
        "Add a greeting\n\nEntire-Checkpoint: #{@checkpoint_id}\n",
        [base_oid],
        update_ref: "refs/heads/main"
      )

    checkpoint_oid =
      commit!(
        agent,
        checkpoint_files(hex(main_oid), Keyword.get(opts, :files_touched, @files_touched)),
        "Checkpoint #{@checkpoint_id}\n",
        []
      )

    :ok = GitAgent.reference_create(agent, @checkpoint_ref, :oid, checkpoint_oid)

    %{main_sha: hex(main_oid), checkpoint_oid: checkpoint_oid}
  end

  @doc """
  The checkpoint tree, as a `path => content` map.

  The sessions recorded in the root `metadata.json` are the pointer entries the
  CLI writes; `0/` holds the session itself.
  """
  @spec checkpoint_files(binary, [binary]) :: %{binary => binary}
  def checkpoint_files(commit_sha, files_touched \\ @files_touched) do
    %{
      "metadata.json" =>
        Jason.encode!(%{
          "cli_version" => "0.11.5",
          "checkpoint_id" => @checkpoint_id,
          "strategy" => "manual-commit",
          "branch" => "main",
          "checkpoints_count" => 1,
          "commit_sha" => commit_sha,
          "files_touched" => files_touched,
          "sessions" => [
            %{
              "metadata" => "/0/metadata.json",
              "transcript" => "/0/full.jsonl",
              "compact_transcript" => "/0/transcript.jsonl",
              "prompt" => "/0/prompt.txt"
            }
          ],
          "token_usage" => %{"input_tokens" => 158, "output_tokens" => 54}
        }),
      "0/metadata.json" => Jason.encode!(%{"session_id" => "sess-1", "agent" => "opencode"}),
      "0/prompt.txt" => "Add a greeting to the README\n",
      "0/full.jsonl" => transcript(),
      "0/transcript.jsonl" => @first_line <> "\n",
      "tasks/task-1/task.json" =>
        Jason.encode!(%{"description" => "Add a greeting", "status" => "completed"})
    }
  end

  @doc "A 150-line transcript, so the checkpoint detail viewer paginates (100 lines per page)."
  @spec transcript :: binary
  def transcript do
    lines = [
      @first_line,
      @second_line
      | Enum.map(3..150, fn index -> ~s({"type":"tool","text":"line #{index}"}) end)
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  @doc "The raw object id of a commit, as a lowercase hex string."
  def hex(oid), do: Base.encode16(oid, case: :lower)

  #
  # Helpers
  #

  defp commit!(agent, files, message, parents, opts \\ []) do
    {:ok, oid} =
      GitAgent.transaction(agent, fn agent ->
        with {:ok, tree_oid} <- write_tree(agent, files) do
          GitAgent.commit_create(
            agent,
            signature(),
            signature(),
            message,
            tree_oid,
            parents,
            opts
          )
        end
      end)

    oid
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
end
