defmodule GitGud.Checkpoints do
  @moduledoc """
  Read access to the AI coding-agent *checkpoints* recorded by the
  [Entire CLI](https://github.com/entireio/cli) and pushed to gitfrank as
  ordinary Git references.

  A checkpoint is one commit's worth of agent work: the user prompts, the agent
  transcript, the files touched and the token usage. The CLI stores it as a
  commit whose tree root *is* the checkpoint tree, and points a reference at it:

      refs/entire/checkpoints/<shard>/<id>     # <shard> = last two characters of <id>

  where `<id>` is a 26-character ULID (older checkpoints use a legacy
  12-character hex id; both are treated as opaque strings here). Repositories
  written by an older CLI keep the same trees on an `entire/checkpoints/v1`
  branch instead, sharded as `<shard>/<rest>/`; both layouts are read.

  Git stays the source of truth: everything is read out of the repository's own
  object store through `GitGud.RepoPool`. The `GitGud.MetaDB` entry written by
  `list/2` is only a droppable cache: the per-checkpoint summaries plus the term
  index `search/3` looks up (one posting per term and session prompt), guarded by
  a watermark of the reference names and target oids it was built from, so it
  invalidates itself as soon as a push moves a checkpoint. `provenance/3` needs
  no index of its own: it reads the touched files off the summaries.

  Deleting a checkpoint ref (`entire clean`, `git push --delete`) needs no special
  handling: the watermark changes, so the next read rebuilds the index without it.
  A checkpoint id can be given in full or as an unambiguous prefix — the "short id"
  the UI shows — and `storage/1` reports what the checkpoints weigh.

  See `guides/Sessions and Checkpoints.md`.
  """

  require Logger

  alias GitGud.MetaDB
  alias GitGud.Repo

  alias GitRekt.Git
  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  @ref_prefix "refs/entire/checkpoints/"

  # The whole `refs/entire/` namespace belongs to the Entire CLI; only the
  # checkpoint shape above is meaningful to gitfrank. A push of any other shape
  # under the namespace is refused so that a stray name cannot sit next to the
  # checkpoints (see `reference_policy/0`).
  @ref_namespace "refs/entire/"
  @trailer ~r/^[ \t]*Entire-Checkpoint:[ \t]*(\S+)[ \t]*$/mi
  @default_max_transcript_bytes 1_048_576
  @default_legacy_branch "entire/checkpoints/v1"
  @hex_oid ~r/\A[0-9a-fA-F]{40}\z/

  # The shortest id prefix `resolve_location/2` expands into a checkpoint id.
  # Shorter input has to match exactly -- otherwise a stray `"0"` would match
  # every checkpoint in the repository.
  @min_id_prefix_length 4

  # Caps for `storage/1`: walking every blob of every checkpoint is bounded, so
  # that an admin report on a very large repository stays cheap. When a cap is
  # hit the reported byte count becomes a documented lower bound.
  @max_storage_checkpoints 500
  @max_storage_objects 200_000

  # Search is deliberately dependency-free: prompts are indexed locally (no
  # embeddings, no external service), with hard caps so that neither the index
  # document nor a single query can grow without bound.
  @max_prompt_bytes 4_096
  @max_session_terms 64
  @max_query_terms 16
  @max_postings 500
  @min_term_length 2

  # Tokens are runs of ASCII letters and digits: checkpoint blobs are not
  # guaranteed to be valid UTF-8, and prompts are overwhelmingly ASCII.
  @token ~r/[a-z0-9]+/

  # Dropped from both the index and the query, so that a natural language query
  # ("add a greeting to the readme") still matches on its meaningful words.
  @stopwords ~w(a an and are as at be by for from has have i if in into is it its of on or that the
                this to was were will with you your)

  @type id :: binary

  @type summary :: %{
          id: id,
          ref: binary,
          source: :ref | :branch,
          oid: binary,
          branch: binary | nil,
          strategy: binary | nil,
          checkpoints_count: non_neg_integer | nil,
          files_touched: [binary],
          sessions: [map],
          session_count: non_neg_integer,
          token_usage: map | nil,
          commit_sha: binary | nil,
          committed_at: DateTime.t() | nil
        }

  @type match :: %{
          checkpoint: summary,
          matched: [binary],
          score: non_neg_integer
        }

  @type checkpoint :: map

  # Where a checkpoint's tree lives: a dedicated reference (`:ref`) or a
  # sub-directory of the legacy `entire/checkpoints/v1` branch (`:branch`).
  @typep location :: %{
           source: :ref | :branch,
           ref: binary,
           id: id,
           oid: binary,
           base: binary
         }

  @doc """
  Returns `true` when checkpoint reading is enabled.

  Configured through `config :gitgud, GitGud.Checkpoints, enabled: false`.
  """
  @spec enabled? :: boolean
  def enabled?, do: config(:enabled, true)

  @doc """
  Returns the reference prefix checkpoints are pushed under.
  """
  @spec ref_prefix :: binary
  def ref_prefix, do: @ref_prefix

  @doc """
  Returns the reference prefixes the Git transports must not advertise.

  Empty while checkpoint reading is enabled; `[ref_prefix/0]` when it is disabled,
  so that a deployment which turned checkpoints off does not keep leaking
  checkpoint ids and counts to every clone and fetch
  (`guides/Sessions and Checkpoints.md` §7, risk 2). `GitGud.SSHServer` and
  `GitGud.SmartHTTPBackend` hand it to `GitRekt.WireProtocol`.
  """
  @spec hidden_reference_prefixes :: [binary]
  def hidden_reference_prefixes, do: if(enabled?(), do: [], else: [@ref_prefix])

  @doc """
  Returns the reference policy the Git transports apply to a `git push`.

  A function `(reference_name -> :ok | {:error, reason})` that
  `GitRekt.WireProtocol.ReceivePack` calls for every reference a push would
  *write* before it is created or moved. It keeps a disabled deployment clean and
  the checkpoint namespace well-formed:

    * while checkpoint reading is disabled, `refs/entire/checkpoints/*` is refused
      outright — a disabled instance stores no checkpoint data at all; and
    * while it is enabled, a checkpoint reference must keep the CLI's
      `refs/entire/checkpoints/<shard>/<id>` shape, so a stray name cannot pollute
      the checkpoint listing; and
    * any other name under `refs/entire/` is refused too — the namespace is the
      CLI's, and only the checkpoint shape is meaningful to gitfrank.

  Every reference outside the namespace is accepted, and the transport enforces
  Git's own reference-name rules on top. Deletions are never offered to the policy: removing
  data is always allowed, which is also what lets a deployment that has turned
  checkpoint reading off still be cleaned up. See
  `guides/Sessions and Checkpoints.md` §7, risk 4.
  """
  @spec reference_policy :: (binary -> :ok | {:error, binary})
  def reference_policy do
    fn name ->
      cond do
        String.starts_with?(name, @ref_prefix) ->
          if enabled?(),
            do: validate_checkpoint_ref(name),
            else: {:error, "checkpoint-reading-disabled"}

        String.starts_with?(name, @ref_namespace) ->
          {:error, "invalid-checkpoint-reference"}

        true ->
          :ok
      end
    end
  end

  @doc """
  Returns the checkpoint ids referenced by a commit `message`.

  Mirrors the CLI: every `Entire-Checkpoint: <id>` trailer counts, and repeated
  trailers are collapsed into one entry.
  """
  @spec checkpoint_ids(binary) :: [id]
  def checkpoint_ids(message) when is_binary(message) do
    @trailer
    |> Regex.scan(message, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Lists the checkpoints of `repo`, newest first.

  Returns the (small) summaries only; use `get/2` for a single checkpoint's raw
  metadata and `session/4` for its transcript.

  Options:

    * `:cache` — when `false`, ignore the cached index and rebuild it (the
      result is still cached). Defaults to `true`.
  """
  @spec list(Repo.t(), keyword) :: {:ok, [summary]} | {:error, term}
  def list(%Repo{} = repo, opts \\ []) do
    if enabled?() do
      with_agent(repo, fn agent ->
        with {:ok, document} <- index(repo, agent, opts) do
          {:ok, sorted(Map.values(document.checkpoints))}
        end
      end)
    else
      {:ok, []}
    end
  end

  @doc """
  Same as `list/2`, but ignores the cached index.
  """
  @spec refresh(Repo.t(), keyword) :: {:ok, [summary]} | {:error, term}
  def refresh(%Repo{} = repo, opts \\ []), do: list(repo, Keyword.put(opts, :cache, false))

  @doc """
  Returns the checkpoint with the given `id`.

  The summary is enriched with the raw `metadata.json` under `:metadata`.
  """
  @spec get(Repo.t(), id) :: {:ok, checkpoint} | {:error, term}
  def get(%Repo{} = repo, id) when is_binary(id) do
    with_agent(repo, &read_checkpoint(&1, id))
  end

  @doc """
  Returns the session at `index` (0-based) of the checkpoint `id`.

  Carries the session `metadata.json`, the user `prompt.txt` and the agent
  transcript as a list of raw JSON Lines.

  Options:

    * `:source` — which transcript to prefer. `:full` (the default) reads the
      agent-native `full.jsonl`; `:compact` reads the CLI's normalised
      `transcript.jsonl`, one message per line. Either falls back to the other
      when the preferred file is absent, and the file actually read is returned
      under `:source` — the compacted transcript is what a UI wants to render,
      while `full.jsonl` is the faithful record.
    * `:max_bytes` — cap on the transcript size (default
      `config :gitgud, GitGud.Checkpoints, max_transcript_bytes: …`). The last,
      possibly partial, line is dropped when the transcript is truncated, so
      every returned line is complete.
  """
  @spec session(Repo.t(), id, non_neg_integer, keyword) :: {:ok, map} | {:error, term}
  def session(%Repo{} = repo, id, index, opts \\ []) when is_binary(id) and is_integer(index) do
    max_bytes =
      Keyword.get(opts, :max_bytes) ||
        config(:max_transcript_bytes, @default_max_transcript_bytes)

    source = Keyword.get(opts, :source, :full)

    with_agent(repo, fn agent ->
      with {:ok, loc} <- resolve_location(agent, id),
           {:ok, commit} <- checkpoint_commit(agent, loc) do
        base = rel(loc, to_string(index))

        with {:ok, metadata} <- read_json_optional(agent, commit, base <> "/metadata.json"),
             {:ok, prompt} <- read_blob(agent, commit, base <> "/prompt.txt"),
             {:ok, transcript, bytes, truncated?, source} <-
               read_transcript(agent, commit, base, max_bytes, source) do
          {:ok,
           %{
             id: loc.id,
             index: index,
             oid: loc.oid,
             metadata: metadata,
             prompt: prompt,
             transcript: transcript,
             transcript_bytes: bytes,
             truncated: truncated?,
             source: source
           }}
        end
      end
    end)
  end

  @doc """
  Returns the subagent tasks recorded for the checkpoint `id`.
  """
  @spec tasks(Repo.t(), id) :: {:ok, [map]} | {:error, term}
  def tasks(%Repo{} = repo, id) when is_binary(id) do
    with_agent(repo, fn agent ->
      with {:ok, loc} <- resolve_location(agent, id),
           {:ok, commit} <- checkpoint_commit(agent, loc) do
        case GitAgent.tree_entries(agent, commit, path: rel(loc, "tasks")) do
          {:ok, entries} ->
            {:ok,
             entries
             |> Enum.filter(&(&1.type == :tree))
             |> Enum.flat_map(&read_task(agent, commit, loc, &1))}

          {:error, _reason} ->
            {:ok, []}
        end
      end
    end)
  end

  @doc """
  Returns the user prompts recorded for the checkpoint `id`.

  One entry per session directory, in index order, each carrying its 0-based
  `:index` and the `prompt.txt` contents (`nil` when the session recorded none).
  Unlike `session/4` the agent transcripts are never read, so this stays cheap
  enough to search across a whole repository — it is also what feeds the prompt
  term index behind `search/3`.
  """
  @spec prompts(Repo.t(), id) ::
          {:ok, [%{index: non_neg_integer, prompt: binary | nil}]} | {:error, term}
  def prompts(%Repo{} = repo, id) when is_binary(id) do
    with_agent(repo, fn agent ->
      with {:ok, loc} <- resolve_location(agent, id),
           {:ok, commit} <- checkpoint_commit(agent, loc) do
        {:ok, prompts_of(agent, commit, loc)}
      end
    end)
  end

  @doc """
  Searches the checkpoints of `repo` by keyword.

  The query is split into terms (lowercase ASCII words; stop words and one
  character terms are dropped, and at most `#{@max_query_terms}` terms are used).
  A checkpoint matches when *every* term is found in one of its summary fields —
  `id`, `branch`, `strategy`, `commit_sha`, `files_touched` (case-insensitive
  substring) — or in one of its session prompts (through the term index built
  alongside the summaries, see `list/2`).

  Returns the matches ranked by `:score` — the matched field labels, weighted
  (`"session <n> prompt"` and `"files_touched"` count 3, everything else 1) —
  and then by recency. Each match carries the `:checkpoint` summary, the
  `:matched` field labels (e.g. `["branch", "session 0 prompt"]`) and the
  `:score`. An empty keyword list matches nothing.

  Agent transcripts are not indexed; use `session/4` to read one.

  Options: the same as `list/2`.
  """
  @spec search(Repo.t(), binary, keyword) :: {:ok, [match]} | {:error, term}
  def search(%Repo{} = repo, query, opts \\ []) when is_binary(query) do
    if enabled?() do
      terms = keywords(query)

      with_agent(repo, fn agent ->
        with {:ok, document} <- index(repo, agent, opts) do
          {:ok, matches(document, terms)}
        end
      end)
    else
      {:ok, []}
    end
  end

  @doc """
  Returns the checkpoints that touched `path`, newest first.

  `path` is matched against each checkpoint's `files_touched`: an exact file, or a
  directory (a trailing `/` is implied, so `lib` matches `lib/gitgud/repo.ex`).
  Each match carries the `:checkpoint` summary, the `:matched` files (the touched
  paths that matched) and a `:score` of `length(matched)`.

  Options: the same as `list/2`.
  """
  @spec provenance(Repo.t(), binary, keyword) :: {:ok, [match]} | {:error, term}
  def provenance(%Repo{} = repo, path, opts \\ []) when is_binary(path) do
    if enabled?() do
      path = normalize_path(path)

      with_agent(repo, fn agent ->
        with {:ok, document} <- index(repo, agent, opts) do
          matches =
            document.checkpoints
            |> Map.values()
            |> sorted()
            |> Enum.flat_map(&provenance_match(&1, path))

          {:ok, matches}
        end
      end)
    else
      {:ok, []}
    end
  end

  @doc """
  Returns what the checkpoints of `repo` weigh.

  `count` is the number of checkpoint locations and `bytes` the summed size of the
  blobs reachable from their trees, each blob counted **once**: Git is
  content-addressed, so a file several checkpoints share is measured a single
  time. The walk is capped (`#{@max_storage_checkpoints}` checkpoints,
  `#{@max_storage_objects}` blobs) so that an admin report cannot melt on a very
  large repository; when a cap is hit `truncated?` is `true` and `bytes` is a lower
  bound.

  This reads Git and is not cached; it is meant for an on-demand admin view.
  """
  @spec storage(Repo.t(), keyword) :: {:ok, map} | {:error, term}
  def storage(%Repo{} = repo, _opts \\ []) do
    if enabled?() do
      with_agent(repo, fn agent ->
        with {:ok, _watermark, locations} <- scan(agent) do
          {bytes, scanned} = storage_bytes(agent, locations)

          {:ok,
           %{count: length(locations), bytes: bytes, truncated?: scanned < length(locations)}}
        end
      end)
    else
      {:ok, %{count: 0, bytes: 0, truncated?: false}}
    end
  end

  @doc """
  Returns the checkpoint ids linked to a commit.

  The link is the `Entire-Checkpoint:` trailer the CLI writes into the commit
  message; a merge commit never carries one.
  """
  @spec commit_ids(Repo.t(), binary) :: {:ok, [id]} | {:error, term}
  def commit_ids(%Repo{} = repo, oid) do
    with_agent(repo, fn agent -> read_commit_ids(agent, oid) end)
  end

  @doc """
  Returns the checkpoints linked to a commit, resolved.
  """
  @spec for_commit(Repo.t(), binary) :: {:ok, [checkpoint]} | {:error, term}
  def for_commit(%Repo{} = repo, oid) do
    with_agent(repo, fn agent ->
      with {:ok, ids} <- read_commit_ids(agent, oid) do
        Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
          case read_checkpoint(agent, id) do
            {:ok, checkpoint} -> {:cont, {:ok, [checkpoint | acc]}}
            {:error, :not_found} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, checkpoints} -> {:ok, Enum.reverse(checkpoints)}
          {:error, _reason} = error -> error
        end
      end
    end)
  end

  @doc """
  Drops the cached checkpoint index for `repo`.

  The next read rebuilds it from Git, so this is always safe to call; it is what
  `GitRekt.GitRepo.push/2` does when a push touches `refs/entire/`.
  """
  @spec invalidate(Repo.t()) :: :ok | {:error, term}
  def invalidate(%Repo{} = repo), do: MetaDB.delete(index_key(repo))

  #
  # Index
  #

  defp index(repo, agent, opts) do
    with {:ok, watermark, locations} <- scan(agent) do
      cached =
        if Keyword.get(opts, :cache, true),
          do: read_cache(repo, watermark),
          else: :miss

      case cached do
        {:ok, document} -> {:ok, document}
        :miss -> build(repo, agent, watermark, locations)
      end
    end
  end

  # A cached document without a term index predates `search/3`; it fails to match
  # and is rebuilt.
  defp read_cache(repo, watermark) do
    case MetaDB.get_raw(index_key(repo)) do
      %{watermark: ^watermark, checkpoints: checkpoints, terms: terms} ->
        {:ok, %{watermark: watermark, checkpoints: checkpoints, terms: terms}}

      _other ->
        :miss
    end
  end

  defp build(repo, agent, watermark, locations) do
    {checkpoints, terms} =
      Enum.reduce(locations, {%{}, %{}}, fn loc, {checkpoints, terms} ->
        case location_document(agent, loc) do
          {:ok, summary, prompts} ->
            {Map.put(checkpoints, summary.id, summary), index_terms(terms, summary, prompts)}

          {:error, reason} ->
            Logger.warning(
              "GitGud.Checkpoints: skipping #{loc.ref} (#{loc.id}): #{inspect(reason)}"
            )

            {checkpoints, terms}
        end
      end)

    document = %{watermark: watermark, checkpoints: checkpoints, terms: terms}
    :ok = MetaDB.put(index_key(repo), document)
    {:ok, document}
  end

  # Keyed by owner/name rather than by `repo.id`: `GitGud.MetaDB` is process-wide
  # and outlives the (sandboxed, rolled back) database rows, while `repo.volume`
  # is the *volume* id and therefore shared by every repository.
  defp index_key(%Repo{owner_login: owner_login, name: name}),
    do: {:checkpoints, owner_login, name}

  #
  # Reading
  #

  defp read_checkpoint(agent, id) do
    with {:ok, loc} <- resolve_location(agent, id),
         {:ok, commit} <- checkpoint_commit(agent, loc),
         {:ok, metadata} <- read_json(agent, commit, rel(loc, "metadata.json")),
         {:ok, timestamp} <- GitAgent.commit_timestamp(agent, commit) do
      {:ok, Map.put(summary(loc, metadata, timestamp), :metadata, metadata)}
    end
  end

  # The summary of one checkpoint together with the session prompts that make it
  # searchable, off a single commit lookup.
  defp location_document(agent, loc) do
    with {:ok, commit} <- checkpoint_commit(agent, loc),
         {:ok, metadata} <- read_json(agent, commit, rel(loc, "metadata.json")),
         {:ok, timestamp} <- GitAgent.commit_timestamp(agent, commit) do
      {:ok, summary(loc, metadata, timestamp), prompts_of(agent, commit, loc)}
    end
  end

  # Best effort: a checkpoint whose session directories cannot be listed is still
  # indexed, it simply has no prompts.
  defp prompts_of(agent, commit, loc) do
    case session_entries(agent, commit, loc) do
      {:ok, entries} -> Enum.map(session_indexes(entries), &read_prompt(agent, commit, loc, &1))
      {:error, _reason} -> []
    end
  end

  defp summary(loc, metadata, timestamp) do
    sessions = List.wrap(metadata["sessions"])

    %{
      id: loc.id,
      ref: loc.ref,
      source: loc.source,
      oid: loc.oid,
      branch: metadata["branch"],
      strategy: metadata["strategy"],
      checkpoints_count: metadata["checkpoints_count"],
      files_touched: List.wrap(metadata["files_touched"]),
      sessions: sessions,
      session_count: length(sessions),
      token_usage: metadata["token_usage"],
      commit_sha: metadata["commit_sha"],
      committed_at: timestamp
    }
  end

  defp read_task(agent, commit, loc, entry) do
    path = rel(loc, "tasks/#{entry.name}/task.json")

    case read_json(agent, commit, path) do
      {:ok, task} -> [%{id: entry.name, path: path, data: task}]
      {:error, _reason} -> []
    end
  end

  # The sessions are the numeric directories at the root of the checkpoint tree.
  defp session_entries(agent, commit, %{base: ""}),
    do: GitAgent.tree_entries(agent, commit)

  defp session_entries(agent, commit, %{base: base}),
    do: GitAgent.tree_entries(agent, commit, path: base)

  defp session_indexes(entries) do
    entries
    |> Enum.filter(&(&1.type == :tree))
    |> Enum.flat_map(fn entry ->
      case Integer.parse(entry.name) do
        {index, ""} -> [index]
        _other -> []
      end
    end)
    |> Enum.sort()
  end

  defp read_prompt(agent, commit, loc, index) do
    case read_blob(agent, commit, rel(loc, "#{index}/prompt.txt")) do
      {:ok, prompt} -> %{index: index, prompt: prompt}
      {:error, _reason} -> %{index: index, prompt: nil}
    end
  end

  defp read_commit_ids(agent, oid) do
    with {:ok, object} <- resolve_object(agent, oid),
         {:ok, commit} <- GitAgent.peel(agent, object, target: :commit),
         {:ok, parents} <- GitAgent.commit_parents(agent, commit),
         {:ok, message} <- GitAgent.commit_message(agent, commit) do
      if length(Enum.to_list(parents)) > 1,
        do: {:ok, []},
        else: {:ok, checkpoint_ids(message)}
    end
  end

  #
  # Search index
  #

  # Folds one checkpoint's session prompts into the term index: `term =>
  # [{checkpoint id, session index}]`.
  defp index_terms(terms, summary, prompts) do
    Enum.reduce(prompts, terms, fn %{index: index, prompt: prompt}, terms ->
      case prompt_text(prompt) do
        nil ->
          terms

        text ->
          Enum.reduce(keywords(text, @max_session_terms), terms, &post(&1, &2, summary.id, index))
      end
    end)
  end

  # The search terms of a piece of text: lowercased, ASCII words and digits, stop
  # words and single characters dropped, at most `limit` of them.
  defp keywords(text, limit \\ @max_query_terms) do
    text
    |> String.downcase()
    |> truncate(@max_prompt_bytes)
    |> scan_terms()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @stopwords or byte_size(&1) < @min_term_length))
    |> Enum.take(limit)
  end

  defp scan_terms(text), do: @token |> Regex.scan(text) |> List.flatten()

  # Postings are capped per term, so a word every prompt happens to use ("code")
  # cannot blow up the index document.
  defp post(term, terms, id, index) do
    postings = Map.get(terms, term, [])

    if {id, index} in postings or length(postings) >= @max_postings,
      do: terms,
      else: Map.put(terms, term, [{id, index} | postings])
  end

  defp prompt_text(nil), do: nil
  defp prompt_text(prompt) when is_binary(prompt), do: prompt

  defp matches(_document, []), do: []

  defp matches(document, terms) do
    document.checkpoints
    |> Map.values()
    |> Enum.map(&match(&1, document, terms))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{-&1.score, -sort_time(&1.checkpoint.committed_at), &1.checkpoint.id})
  end

  # Every term has to hit at least one field; a checkpoint that misses one does
  # not match at all.
  defp match(checkpoint, document, terms) do
    hits =
      for term <- terms,
          fields = fields_for(checkpoint, document, term),
          fields != [],
          do: fields

    if length(hits) == length(terms) do
      matched = hits |> List.flatten() |> Enum.uniq() |> Enum.sort()

      %{
        checkpoint: checkpoint,
        matched: matched,
        score: Enum.sum(Enum.map(matched, &weight/1))
      }
    end
  end

  defp fields_for(summary, document, term) do
    []
    |> match_field("id", summary.id, term)
    |> match_field("branch", summary.branch, term)
    |> match_field("strategy", summary.strategy, term)
    |> match_field("commit_sha", summary.commit_sha, term)
    |> match_field("files_touched", summary.files_touched, term)
    |> prompt_fields(document, summary.id, term)
  end

  defp match_field(fields, _name, nil, _term), do: fields

  defp match_field(fields, name, value, term) do
    if contains?(value, term), do: fields ++ [name], else: fields
  end

  defp prompt_fields(fields, document, id, term) do
    labels =
      document.terms
      |> Map.get(term, [])
      |> Enum.flat_map(fn {posting_id, index} ->
        if posting_id == id, do: ["session #{index} prompt"], else: []
      end)

    fields ++ labels
  end

  defp contains?(value, term) when is_binary(value),
    do: value |> String.downcase() |> String.contains?(term)

  defp contains?(value, term) when is_list(value), do: Enum.any?(value, &contains?(&1, term))
  defp contains?(_value, _term), do: false

  defp weight("session " <> _rest), do: 3
  defp weight("files_touched"), do: 3
  defp weight(_label), do: 1

  defp provenance_match(checkpoint, path) do
    case Enum.filter(checkpoint.files_touched, &touched?(&1, path)) do
      [] -> []
      files -> [%{checkpoint: checkpoint, matched: files, score: length(files)}]
    end
  end

  # An exact file, or any file below `path` (i.e. `path` is a directory).
  defp touched?(file, path), do: file == path or String.starts_with?(file, path <> "/")

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max)

  #
  # Scanning
  #

  # Returns the index watermark and the checkpoint locations, both derived from a
  # single listing of the repository references.
  defp scan(agent) do
    with {:ok, refs} <- GitAgent.references(agent) do
      refs = Enum.map(refs, &{to_string(&1), Git.oid_fmt(&1.oid)})

      locations =
        for {ref, oid} <- refs, String.starts_with?(ref, @ref_prefix) do
          %{source: :ref, ref: ref, id: Path.basename(ref), oid: oid, base: ""}
        end

      {legacy_ref, legacy_locations} = legacy_locations(agent, refs)

      watermark =
        refs
        |> Enum.filter(fn {ref, _oid} ->
          String.starts_with?(ref, @ref_prefix) or ref == legacy_ref
        end)
        |> Map.new()

      {:ok, watermark, locations ++ legacy_locations}
    end
  end

  defp legacy_locations(agent, refs) do
    with branch when is_binary(branch) <- legacy_branch(),
         {ref, oid} <- Enum.find(refs, fn {ref, _oid} -> ref == "refs/heads/" <> branch end) do
      {ref, read_legacy_locations(agent, ref, oid)}
    else
      _other -> {nil, []}
    end
  end

  defp read_legacy_locations(agent, ref, oid) do
    with {:ok, object} <- GitAgent.object(agent, Git.oid_parse(oid)),
         {:ok, commit} <- GitAgent.peel(agent, object, target: :commit),
         {:ok, shards} <- GitAgent.tree_entries(agent, commit) do
      shards
      |> Enum.filter(&(&1.type == :tree))
      |> Enum.flat_map(&read_legacy_shard(agent, commit, ref, oid, &1))
    else
      {:error, reason} ->
        Logger.warning(
          "GitGud.Checkpoints: cannot read legacy checkpoints from #{ref}: #{inspect(reason)}"
        )

        []
    end
  end

  defp read_legacy_shard(agent, commit, ref, oid, shard) do
    case GitAgent.tree_entries(agent, commit, path: shard.name) do
      {:ok, entries} ->
        for entry <- entries, entry.type == :tree do
          %{
            source: :branch,
            ref: ref,
            id: shard.name <> entry.name,
            oid: oid,
            base: shard.name <> "/" <> entry.name
          }
        end

      {:error, _reason} ->
        []
    end
  end

  # Resolves a checkpoint id, accepting an unambiguous prefix — the "short id" the
  # UI, a commit message or a log shows — so that it works everywhere the full ULID
  # does.
  defp resolve_location(agent, id) do
    with {:ok, _watermark, locations} <- scan(agent) do
      case Enum.filter(locations, &id_match?(&1.id, id)) do
        [] -> {:error, :not_found}
        [location] -> {:ok, location}
        _many -> {:error, :ambiguous}
      end
    end
  end

  # A full id, or an unambiguous prefix of one. The comparison is case-insensitive:
  # checkpoints are uppercase Crockford base32 while legacy ids are lowercase hex,
  # and a user pastes whichever they have.
  defp id_match?(full, id) when byte_size(id) >= @min_id_prefix_length,
    do: String.starts_with?(String.downcase(full), String.downcase(id))

  defp id_match?(full, id), do: full == id

  defp checkpoint_commit(agent, loc) do
    with {:ok, object} <- GitAgent.object(agent, Git.oid_parse(loc.oid)),
         {:ok, commit} <- GitAgent.peel(agent, object, target: :commit) do
      {:ok, commit}
    end
  end

  # A checkpoint reference must keep the shape the CLI writes; anything else under
  # the prefix is refused. Checkpoint ids are at least 12 characters (26 for a
  # ULID, 12 for a legacy hex id) and the shard is their last two characters.
  defp validate_checkpoint_ref(name) do
    case name |> String.replace_prefix(@ref_prefix, "") |> String.split("/") do
      [shard, id] when byte_size(shard) == 2 and byte_size(id) >= 12 -> :ok
      _other -> {:error, "invalid-checkpoint-reference"}
    end
  end

  #
  # Storage
  #

  # Returns `{bytes, scanned}`, where `scanned` is the number of checkpoints that
  # were walked; `scanned < length(locations)` means a cap was hit.
  defp storage_bytes(agent, locations) do
    {seen, bytes, scanned} =
      Enum.reduce_while(locations, {%{}, 0, 0}, fn loc, {seen, bytes, scanned} ->
        if scanned >= @max_storage_checkpoints or map_size(seen) >= @max_storage_objects do
          {:halt, {seen, bytes, scanned}}
        else
          {seen, added} = location_bytes(agent, loc, seen)
          {:cont, {seen, bytes + added, scanned + 1}}
        end
      end)

    {bytes, scanned}
  end

  defp location_bytes(agent, loc, seen) do
    case checkpoint_commit(agent, loc) do
      {:ok, commit} -> tree_bytes(agent, commit, loc, "", seen)
      {:error, _reason} -> {seen, 0}
    end
  end

  # Walks a checkpoint tree, adding the size of every blob to `seen` at most once.
  defp tree_bytes(agent, commit, loc, path, seen) do
    case checkpoint_tree_entries(agent, commit, loc, path) do
      {:ok, entries} ->
        Enum.reduce(entries, {seen, 0}, fn entry, {seen, bytes} ->
          cond do
            map_size(seen) >= @max_storage_objects -> {seen, bytes}
            entry.type == :tree -> descend(agent, commit, loc, path, entry, seen, bytes)
            entry.type == :blob -> blob_bytes(agent, entry, seen, bytes)
            true -> {seen, bytes}
          end
        end)

      {:error, _reason} ->
        {seen, 0}
    end
  end

  defp descend(agent, commit, loc, path, entry, seen, bytes) do
    {seen, added} = tree_bytes(agent, commit, loc, join_path(path, entry.name), seen)
    {seen, bytes + added}
  end

  defp blob_bytes(agent, entry, seen, bytes) do
    oid = Git.oid_fmt(entry.oid)

    if Map.has_key?(seen, oid) do
      {seen, bytes}
    else
      case blob_size(agent, entry) do
        {:ok, size} -> {Map.put(seen, oid, size), bytes + size}
        {:error, _reason} -> {seen, bytes}
      end
    end
  end

  defp blob_size(agent, entry) do
    with {:ok, blob} <- GitAgent.peel(agent, entry) do
      GitAgent.blob_size(agent, blob)
    end
  end

  # The entries at `path` inside a location's tree; a legacy location is rooted at
  # its `<shard>/<rest>/` sub-directory of the branch tip.
  defp checkpoint_tree_entries(agent, commit, loc, path) do
    case tree_path(loc, path) do
      "" -> GitAgent.tree_entries(agent, commit)
      path -> GitAgent.tree_entries(agent, commit, path: path)
    end
  end

  defp tree_path(%{base: ""}, path), do: path
  defp tree_path(%{base: base}, ""), do: base
  defp tree_path(%{base: base}, path), do: base <> "/" <> path

  defp join_path("", name), do: name
  defp join_path(path, name), do: path <> "/" <> name

  #
  # Blobs
  #

  defp read_blob(agent, commit, path) do
    with {:ok, entry} <- GitAgent.tree_entry_by_path(agent, commit, path),
         {:ok, blob} <- GitAgent.peel(agent, entry),
         {:ok, content} <- GitAgent.blob_content(agent, blob) do
      {:ok, content}
    end
  end

  defp read_json(agent, commit, path) do
    with {:ok, content} <- read_blob(agent, commit, path),
         {:ok, value} <- decode_json(content) do
      {:ok, value}
    end
  end

  defp read_json_optional(agent, commit, path) do
    case read_json(agent, commit, path) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp read_first_blob(_agent, _commit, []), do: {:error, :not_found}

  defp read_first_blob(agent, commit, [{path, source} | paths]) do
    case read_blob(agent, commit, path) do
      {:ok, content} -> {:ok, content, source}
      {:error, _reason} -> read_first_blob(agent, commit, paths)
    end
  end

  defp read_transcript(agent, commit, base, max_bytes, source) do
    with {:ok, content, source} <-
           read_first_blob(agent, commit, transcript_candidates(base, source)) do
      {lines, truncated?} = take_lines(content, max_bytes)
      {:ok, lines, byte_size(content), truncated?, source}
    end
  end

  # The agent-native `full.jsonl` is the faithful record but is not necessarily
  # JSON Lines (OpenCode writes a pretty-printed JSON document); the CLI's
  # normalised `transcript.jsonl` is one message per line and is what a UI
  # renders. Prefer the requested one, fall back to the other.
  defp transcript_candidates(base, :compact),
    do: [{base <> "/transcript.jsonl", :compact}, {base <> "/full.jsonl", :full}]

  defp transcript_candidates(base, _source),
    do: [{base <> "/full.jsonl", :full}, {base <> "/transcript.jsonl", :compact}]

  defp take_lines(content, max_bytes) when byte_size(content) <= max_bytes,
    do: {split_lines(content), false}

  defp take_lines(content, max_bytes) do
    # Drop the last, possibly partial, line so that every line returned is whole.
    lines =
      content
      |> binary_part(0, max_bytes)
      |> :binary.split("\n", [:global])
      |> Enum.drop(-1)
      |> Enum.join("\n")

    {split_lines(lines), true}
  end

  defp split_lines(content) do
    content
    |> :binary.split("\n", [:global])
    |> Enum.reject(&(&1 == ""))
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  #
  # Helpers
  #

  defp with_agent(%Repo{} = repo, fun) do
    with {:ok, agent} <- GitRepo.get_agent(repo) do
      GitAgent.transaction(agent, fun)
    end
  end

  defp resolve_object(agent, oid) when is_binary(oid) and byte_size(oid) == 20,
    do: GitAgent.object(agent, oid)

  defp resolve_object(agent, oid) when is_binary(oid) do
    with {:ok, parsed} <- parse_oid(oid) do
      GitAgent.object(agent, parsed)
    end
  end

  defp parse_oid(oid) do
    if oid =~ @hex_oid, do: {:ok, Git.oid_parse(oid)}, else: {:error, :invalid_oid}
  end

  defp rel(%{base: ""}, path), do: path
  defp rel(%{base: base}, path), do: base <> "/" <> path

  defp sorted(checkpoints) do
    Enum.sort_by(checkpoints, &{sort_time(&1.committed_at), &1.id}, :desc)
  end

  defp sort_time(nil), do: 0
  defp sort_time(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp)

  defp legacy_branch, do: config(:legacy_branch, @default_legacy_branch)

  defp config(key, default),
    do: Keyword.get(Application.get_env(:gitgud, __MODULE__, []), key, default)
end
