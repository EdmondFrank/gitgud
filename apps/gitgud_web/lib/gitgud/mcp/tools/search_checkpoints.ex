defmodule GitGud.MCP.Tools.SearchCheckpoints do
  @moduledoc """
  MCP tool `search_checkpoints` — keyword search across a repository's AI
  coding-agent checkpoints.

  The search runs against the prompt term index `GitGud.Checkpoints.search/3`
  keeps in `GitGud.MetaDB` (no Git read): every query term has to match the
  checkpoint id, branch, strategy, commit, touched files or one of its session
  prompts, and the matches carry the labels that matched.

  Agent transcripts are *not* indexed — they can be arbitrarily large. With
  `include_transcripts: true` the newest `@transcript_scan_limit` checkpoints are
  additionally read through `GitGud.Checkpoints.session/4`, each capped at
  `@max_transcript_bytes`, and a checkpoint whose transcript matches is added to
  the results (or annotated with `"session <n> transcript"`).

  See `guides/Sessions and Checkpoints.md`.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Checkpoints
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  # Never read the transcripts of more than this many of the most recent
  # checkpoints, and never more than `@max_transcript_bytes` of a single one.
  @transcript_scan_limit 10
  @max_transcript_bytes 65_536

  def name, do: "search_checkpoints"

  @impl true
  def description do
    "Search a repository's AI coding-agent checkpoints by keyword, matching the checkpoint id, branch, touched files and session prompts."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")

    field(:query, {:required, :string}, description: "Search text, matched case-insensitively.")

    field(:limit, :integer, description: "Maximum matches to return (1-100).", default: 25)

    field(:include_transcripts, :boolean,
      description: "Also scan the agent transcripts of the most recent checkpoints (slower).",
      default: false
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    query = params[:query] |> to_string() |> String.trim()
    limit = Helpers.clamp_limit(params[:limit])

    result =
      with :ok <- validate_query(query),
           {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, matches} <- Checkpoints.search(repo, query) do
        matches = merge_transcript_matches(repo, params, query, matches)

        {:ok,
         %{
           "total_count" => length(matches),
           "matches" => matches |> Enum.take(limit) |> Enum.map(&Helpers.checkpoint_match/1)
         }}
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp validate_query(""), do: {:error, "empty_query"}
  defp validate_query(_query), do: :ok

  defp merge_transcript_matches(repo, %{include_transcripts: true}, query, matches) do
    with {:ok, checkpoints} <- Checkpoints.list(repo) do
      terms = terms(query)

      checkpoints
      |> Enum.take(@transcript_scan_limit)
      |> Enum.reduce(matches, fn checkpoint, matches ->
        case transcript_matches(checkpoint, repo, terms) do
          [] -> matches
          labels -> add_match(matches, checkpoint, labels)
        end
      end)
      |> sort_matches()
    else
      _other -> matches
    end
  end

  defp merge_transcript_matches(_repo, _params, _query, matches), do: matches

  defp transcript_matches(%{session_count: count} = checkpoint, repo, terms) when count > 0 do
    Enum.flat_map(0..(count - 1), fn index ->
      case Checkpoints.session(repo, checkpoint.id, index, max_bytes: @max_transcript_bytes) do
        {:ok, session} ->
          if transcript_contains?(session.transcript, terms),
            do: ["session #{index} transcript"],
            else: []

        {:error, _reason} ->
          []
      end
    end)
  end

  defp transcript_matches(_checkpoint, _repo, _terms), do: []

  defp transcript_contains?(_lines, []), do: false

  defp transcript_contains?(lines, terms) do
    text = lines |> Enum.join("\n") |> String.downcase()
    Enum.all?(terms, &String.contains?(text, &1))
  end

  # A checkpoint that matched only through its transcript is added, one that
  # already matched is annotated; either way the weight matches the prompt
  # labels `GitGud.Checkpoints.search/3` assigns.
  defp add_match(matches, checkpoint, labels) do
    case Enum.find_index(matches, &(&1.checkpoint.id == checkpoint.id)) do
      nil ->
        [
          %{checkpoint: checkpoint, matched: Enum.sort(labels), score: length(labels) * 3}
          | matches
        ]

      index ->
        List.update_at(matches, index, fn match ->
          matched = Enum.uniq(match.matched ++ labels) |> Enum.sort()
          %{match | matched: matched, score: match.score + length(labels) * 3}
        end)
    end
  end

  defp sort_matches(matches) do
    Enum.sort_by(matches, fn %{checkpoint: checkpoint, score: score} ->
      time = if checkpoint.committed_at, do: DateTime.to_unix(checkpoint.committed_at), else: 0
      {-score, -time, checkpoint.id}
    end)
  end

  # Shape of the terms a transcript is scanned for; the domain tokenizer
  # (`GitGud.Checkpoints.search/3`) filters stop words and one character terms on
  # top, which for this bounded, best-effort scan is not worth duplicating.
  defp terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.uniq()
  end
end
