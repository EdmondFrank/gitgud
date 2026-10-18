defmodule GitGud.Web.CheckpointLive do
  @moduledoc """
  Live view listing and rendering the AI coding-agent *checkpoints* the
  [Entire CLI](https://github.com/entireio/cli) records and pushes to a
  repository as ordinary Git references.

  Checkpoints are read out of the repository's own object store through
  `GitGud.Checkpoints`; nothing is duplicated into the database. The `:sessions`
  action lists them, the `:session` action renders one. See
  `guides/Sessions and Checkpoints.md`.
  """

  use GitGud.Web, :live_view

  require Logger

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  alias GitGud.Checkpoints
  alias GitGud.DB
  alias GitGud.DBQueryable
  alias GitGud.IssueQuery
  alias GitGud.RepoQuery

  @checkpoint_page_size 20
  @transcript_page_size 100

  #
  # Callbacks
  #

  @impl true
  def mount(%{"user_login" => user_login, "repo_name" => repo_name} = _params, session, socket) do
    {
      :ok,
      socket
      |> authenticate(session)
      |> assign(
        checkpoints: [],
        page: nil,
        query: "",
        matched: %{},
        storage: nil,
        checkpoint: nil,
        session_index: 0,
        session: nil,
        transcript_page: nil,
        tasks: [],
        diff: nil
      )
      |> assign_repo!(user_login, repo_name)
      |> assign_repo_open_issue_count()
    }
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    case assign_checkpoint!(socket, id, params) do
      {:ok, socket} ->
        {:noreply, assign_page_title(socket)}

      {:error, reason} ->
        Logger.warning(
          "GitGud.Web.CheckpointLive: cannot read checkpoint #{id}: #{inspect(reason)}"
        )

        {:noreply,
         socket
         |> put_flash(:error, checkpoint_error(reason))
         |> push_navigate(to: sessions_path(socket.assigns.repo))}
    end
  end

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_checkpoints(params) |> assign_page_title()}
  end

  #
  # Helpers
  #

  defp checkpoint_error(:ambiguous), do: "That checkpoint id matches more than one checkpoint."
  defp checkpoint_error(_reason), do: "Checkpoint not found."

  defp assign_repo!(socket, user_login, repo_name) do
    query =
      DBQueryable.query({RepoQuery, :user_repo_query}, [user_login, repo_name],
        viewer: current_user(socket)
      )

    assign(socket, :repo, DB.one!(query))
  end

  defp assign_repo_open_issue_count(socket) do
    assign(
      socket,
      :repo_open_issue_count,
      IssueQuery.count_repo_issues(socket.assigns.repo, status: :open)
    )
  end

  defp assign_page_title(socket) do
    assign(
      socket,
      :page_title,
      GitGud.Web.CodebaseView.title(socket.assigns.live_action, socket.assigns)
    )
  end

  # The Sessions list is either the whole (cached) checkpoint index or, with a `q`
  # parameter, the matches `GitGud.Checkpoints.search/3` returns — the same cached
  # index, so searching costs no Git read. `:matched` carries the labels rendered
  # next to each row.
  defp assign_checkpoints(socket, params) do
    query = params["q"] |> to_string() |> String.trim()

    {checkpoints, matched} =
      case query do
        "" ->
          {list_checkpoints(socket.assigns.repo), %{}}

        query ->
          case Checkpoints.search(socket.assigns.repo, query) do
            {:ok, matches} ->
              {Enum.map(matches, & &1.checkpoint),
               Map.new(matches, &{&1.checkpoint.id, &1.matched})}

            {:error, reason} ->
              Logger.warning(
                "GitGud.Web.CheckpointLive: cannot search checkpoints: #{inspect(reason)}"
              )

              {[], %{}}
          end
      end

    socket
    |> assign(:query, query)
    |> assign(:matched, matched)
    |> assign(:page, paginate(checkpoints, int_param(params, "p", 1), @checkpoint_page_size))
    |> assign_storage()
  end

  # An admin-only storage report: how many checkpoints the repository carries and
  # what they weigh. It walks the checkpoint trees, so it is only computed for a
  # viewer who can administer the repository (and never for a search).
  defp assign_storage(socket) do
    storage =
      if authorized?(socket, socket.assigns.repo, :admin) do
        case Checkpoints.storage(socket.assigns.repo) do
          {:ok, storage} ->
            storage

          {:error, reason} ->
            Logger.warning(
              "GitGud.Web.CheckpointLive: cannot measure checkpoint storage: #{inspect(reason)}"
            )

            nil
        end
      end

    assign(socket, :storage, storage)
  end

  defp list_checkpoints(repo) do
    case Checkpoints.list(repo) do
      {:ok, checkpoints} ->
        checkpoints

      {:error, reason} ->
        Logger.warning("GitGud.Web.CheckpointLive: cannot list checkpoints: #{inspect(reason)}")
        []
    end
  end

  defp assign_checkpoint!(socket, id, params) do
    case Checkpoints.get(socket.assigns.repo, id) do
      {:ok, checkpoint} ->
        {:ok,
         socket
         |> assign(:checkpoint, checkpoint)
         |> assign_session(checkpoint, params)
         |> assign_tasks(checkpoint.id)
         |> assign_diff(checkpoint)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assign_session(socket, checkpoint, params) do
    index = session_index(params, checkpoint)
    page = max(int_param(params, "page", 1), 1)

    session =
      case Checkpoints.session(socket.assigns.repo, checkpoint.id, index) do
        {:ok, session} ->
          session

        {:error, reason} ->
          Logger.warning(
            "GitGud.Web.CheckpointLive: cannot read session #{index} of #{checkpoint.id}: #{inspect(reason)}"
          )

          nil
      end

    transcript_page =
      if session, do: paginate(session.transcript, page, @transcript_page_size), else: nil

    assign(socket, session_index: index, session: session, transcript_page: transcript_page)
  end

  defp assign_tasks(socket, id) do
    tasks =
      case Checkpoints.tasks(socket.assigns.repo, id) do
        {:ok, tasks} -> tasks
        {:error, _reason} -> []
      end

    assign(socket, :tasks, tasks)
  end

  defp assign_diff(socket, checkpoint) do
    with sha when is_binary(sha) <- checkpoint.metadata["commit_sha"],
         {:ok, agent} <- GitRepo.get_agent(socket.assigns.repo),
         {:ok, diff} <- GitAgent.transaction(agent, &read_diff(&1, sha)) do
      assign(socket, :diff, diff)
    else
      _other -> assign(socket, :diff, nil)
    end
  end

  defp read_diff(agent, sha) do
    with {:ok, {object, _ref}} <- GitAgent.revision(agent, sha),
         {:ok, commit} <- GitAgent.peel(agent, object, target: :commit),
         {:ok, parents} <- GitAgent.commit_parents(agent, commit) do
      parent = parents |> Enum.to_list() |> List.first()

      with {:ok, diff} <- GitAgent.diff(agent, parent, commit),
           {:ok, stats} <- GitAgent.diff_stats(agent, diff),
           {:ok, deltas} <- GitAgent.diff_deltas(agent, diff) do
        {:ok, %{oid: sha, stats: stats, deltas: deltas}}
      end
    end
  end

  defp session_index(params, checkpoint) do
    count = checkpoint.session_count

    if count > 0,
      do: min(max(int_param(params, "session", 0), 0), count - 1),
      else: 0
  end

  # Offset pagination over an in-memory list (the checkpoint index is small and
  # cached in `GitGud.MetaDB`), shared by the checkpoint list and the transcript.
  defp paginate(list, page, size) do
    count = max(div(length(list) + size - 1, size), 1)
    page = min(max(page, 1), count)

    %{
      current: page,
      count: count,
      previous?: page > 1,
      next?: page < count,
      slice: Enum.slice(list, (page - 1) * size, size)
    }
  end

  defp int_param(params, key, default) do
    case Integer.parse(params[key] || "") do
      {value, _rest} -> value
      :error -> default
    end
  end

  defp sessions_path(repo), do: ~p"/#{repo.owner_login}/#{repo.name}/sessions"

  # Keeps the search query in the pagination links.
  defp sessions_page_path(query, page) do
    params = if query == "", do: [p: page], else: [q: query, p: page]
    "?" <> URI.encode_query(params)
  end

  defp session_path(repo, id), do: ~p"/#{repo.owner_login}/#{repo.name}/sessions/#{id}"

  defp commit_path(repo, sha), do: ~p"/#{repo.owner_login}/#{repo.name}/commit/#{sha}"

  defp blob_path(repo, revision, path),
    do: ~p"/#{repo.owner_login}/#{repo.name}/blob/#{revision}/#{path}"

  # `Entire-Checkpoint:` commit shas are 40 lowercase hex characters; the
  # checkpoint's own tree oid is a raw binary that needs formatting.
  defp short_oid(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp short_oid(_sha), do: nil

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MiB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GiB"

  defp token_summary(nil), do: nil

  defp token_summary(token_usage) when is_map(token_usage) do
    case {token_usage["input_tokens"], token_usage["output_tokens"]} do
      {nil, nil} -> nil
      {input, output} -> "#{input || 0} in / #{output || 0} out"
    end
  end

  defp token_summary(_token_usage), do: nil

  defp delta_stats(delta) do
    Enum.reduce(delta.hunks, {0, 0}, fn hunk, acc ->
      Enum.reduce(hunk.lines, acc, fn line, {adds, dels} ->
        case line.origin do
          "+" -> {adds + 1, dels}
          "-" -> {adds, dels + 1}
          _other -> {adds, dels}
        end
      end)
    end)
  end

  # A transcript line is a raw JSON Line; decode it for display when possible.
  defp transcript_cell(line) do
    case Jason.decode(line) do
      {:ok, entry} when is_map(entry) ->
        type = entry["type"] || entry["role"] || "entry"
        text = entry["text"] || entry["content"] || entry["message"] || line
        {to_string(type), display_text(text)}

      _other ->
        {"raw", line}
    end
  end

  defp display_text(text) when is_binary(text), do: text
  defp display_text(text), do: Jason.encode!(text)
end
