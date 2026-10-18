defmodule GitGud.Web.CheckpointFactory do
  @moduledoc """
  Test fixture that writes an Entire-CLI shaped checkpoint into a repository's own
  object store: a two-commit history (the second commit carrying the
  `Entire-Checkpoint:` trailer), the checkpoint tree root, and the
  `refs/entire/checkpoints/<shard>/<id>` reference pointing at it.

  Both transcripts are shaped the way the CLI 0.11.5 writes them:

    * `0/full.jsonl` — the agent-native record, one JSON object per line;
    * `0/transcript.jsonl` — the compacted, agent-normalised form, one message
      per line with `content` a list of parts.

  Each carries #{150} messages, so the checkpoint viewer paginates (100 per page).
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

  @prompt "Add a greeting to the README"
  @reply "Done — added it."
  @tool "write"
  @timestamp "2026-01-02T03:04:05.000Z"
  @transcript_lines 150

  def checkpoint_id, do: @checkpoint_id
  def checkpoint_ref, do: @checkpoint_ref
  def prompt, do: @prompt
  def reply, do: @reply
  def tool, do: @tool
  def transcript_lines, do: @transcript_lines

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
        checkpoint_files(Keyword.get(opts, :files_touched, @files_touched)),
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
  @spec checkpoint_files([binary]) :: %{binary => binary}
  def checkpoint_files(files_touched \\ @files_touched) do
    %{
      "metadata.json" =>
        Jason.encode!(%{
          "cli_version" => "0.11.5",
          "checkpoint_id" => @checkpoint_id,
          "strategy" => "manual-commit",
          "branch" => "main",
          "checkpoints_count" => 1,
          # The CLI 0.11.5 records no `commit_sha`: the only link to the user's commit
          # is the `Entire-Checkpoint:` trailer `write!/2` puts in it, so a
          # checkpoint's `commit_sha` has to be resolved from that trailer.
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
      "0/metadata.json" =>
        Jason.encode!(%{
          "session_id" => "sess-1",
          "agent" => "opencode",
          "model" => "kimi-k2.5"
        }),
      "0/prompt.txt" => @prompt <> "\n",
      "0/full.jsonl" => full_transcript(),
      "0/transcript.jsonl" => compact_transcript(),
      "tasks/task-1/task.json" =>
        Jason.encode!(%{"description" => "Add a greeting", "status" => "completed"})
    }
  end

  @doc """
  The agent-native `0/full.jsonl` — one JSON object per line, one per message.
  """
  @spec full_transcript :: binary
  def full_transcript do
    transcript(@transcript_lines, &full_line/1)
  end

  @doc """
  The compacted `0/transcript.jsonl` — the CLI's normalised, agent-agnostic form.

  The first three messages are a prompt, a tool call and a reply; the rest are a
  filler `text` part, so a page of it is distinguishable from the next.
  """
  @spec compact_transcript :: binary
  def compact_transcript do
    transcript(@transcript_lines, &compact_line/1)
  end

  @doc "The raw object id of a commit, as a lowercase hex string."
  def hex(oid), do: Base.encode16(oid, case: :lower)

  #
  # Transcript lines
  #

  defp full_line(1) do
    native("user", [%{"type" => "text", "text" => @prompt}])
  end

  defp full_line(2) do
    native("assistant", [
      %{
        "type" => "tool",
        "tool" => @tool,
        "state" => %{
          "status" => "completed",
          "input" => %{"filePath" => "README.md", "content" => "hello world\n"},
          "output" => "Wrote file successfully."
        }
      }
    ])
  end

  defp full_line(index) do
    native("assistant", [%{"type" => "text", "text" => "line #{index}"}])
  end

  defp native(role, parts) do
    Jason.encode!(%{
      "info" => %{"role" => role, "time" => %{"created" => 1_767_326_645_000}},
      "parts" => parts
    })
  end

  defp compact_line(1) do
    compact("user", 0, [%{"id" => "prt-1", "text" => @prompt}])
  end

  defp compact_line(2) do
    compact("assistant", 49, [
      %{
        "id" => "functions.write:0",
        "name" => @tool,
        "type" => "tool_use",
        "input" => %{"filePath" => "README.md", "content" => "hello world\n"},
        "result" => %{"output" => "Wrote file successfully.", "status" => "success"}
      }
    ])
  end

  defp compact_line(3) do
    compact("assistant", 109, [%{"type" => "text", "text" => @reply}])
  end

  defp compact_line(index) do
    compact("assistant", 0, [%{"type" => "text", "text" => "line #{index}"}])
  end

  defp compact(type, input_tokens, content) do
    Jason.encode!(%{
      "v" => 1,
      "agent" => "opencode",
      "cli_version" => "0.11.5",
      "type" => type,
      "ts" => @timestamp,
      "input_tokens" => input_tokens,
      "output_tokens" => 18,
      "content" => content
    })
  end

  defp transcript(count, line) do
    Enum.map_join(1..count, "\n", line) <> "\n"
  end

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
