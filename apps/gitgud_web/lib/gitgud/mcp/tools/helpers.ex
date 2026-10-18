defmodule GitGud.MCP.Tools.Helpers do
  @moduledoc """
  Shared helpers for `GitGud.MCP.Tools.*` modules.

  Provides the JSON envelope used by every tool (`{"ok": true, "data": …}` /
  `{"ok": false, "error": …, "detail": …}`), the Anubis response wrapper, input
  clamping helpers, and serializers that turn domain structs into stable, small
  JSON maps.
  """

  alias Anubis.Server.Response

  alias GitGud.Comment
  alias GitGud.Issue
  alias GitGud.IssueLabel
  alias GitGud.IssueQuery
  alias GitGud.Release
  alias GitGud.Repo
  alias GitGud.User

  alias GitGud.MCP.Authorization

  alias GitRekt.Git
  alias GitRekt.GitRef
  alias GitRekt.GitTag
  alias GitRekt.GitTreeEntry

  @doc """
  Wraps a `{:ok, data} | {:error, reason}` result into a tool response.
  """
  def reply(frame, {:ok, data}), do: {:reply, Response.json(Response.tool(), ok(data)), frame}

  def reply(frame, {:error, {:validation, errors}}) do
    {:reply, Response.json(Response.tool(), error("validation_error", errors)), frame}
  end

  def reply(frame, {:error, reason}),
    do: {:reply, Response.json(Response.tool(), error(reason)), frame}

  def ok(data), do: %{"ok" => true, "data" => data}

  def error(reason, detail \\ nil)
  def error(reason, nil), do: %{"ok" => false, "error" => reason_string(reason)}

  def error(reason, detail),
    do: %{"ok" => false, "error" => reason_string(reason), "detail" => detail}

  @doc "Returns the user authenticated for the current request."
  def current_user(frame), do: frame.assigns[:current_user]

  #
  # Input helpers
  #

  def clamp_limit(nil), do: 25
  def clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(100)
  def clamp_limit(_other), do: 25

  def clamp_offset(nil), do: 0
  def clamp_offset(n) when is_integer(n) and n > 0, do: n
  def clamp_offset(_other), do: 0

  def clamp_max_bytes(nil), do: 262_144
  def clamp_max_bytes(n) when is_integer(n), do: n |> max(1) |> min(1_048_576)
  def clamp_max_bytes(_other), do: 262_144

  def issue_status(nil), do: nil
  def issue_status("all"), do: nil
  def issue_status("open"), do: :open
  def issue_status("close"), do: :close
  def issue_status("closed"), do: :close
  def issue_status(:open), do: :open
  def issue_status(:close), do: :close
  def issue_status(_other), do: nil

  def labels(nil), do: []
  def labels(""), do: []

  def labels(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def labels(_other), do: []

  #
  # Serializers
  #

  @doc "Formats a raw Git object id (20-byte binary) as a hex string; passes through already-formatted ids."
  def oid(nil), do: nil

  def oid(oid) when is_binary(oid) do
    if byte_size(oid) == 20, do: Git.oid_fmt(oid), else: oid
  end

  @doc "Parses a 40-character hex object id into its raw binary form."
  def parse_oid(oid) when is_binary(oid) do
    if oid =~ ~r/\A[0-9a-fA-F]{40}\z/ do
      {:ok, Git.oid_parse(oid)}
    else
      {:error, "invalid_oid"}
    end
  end

  def parse_oid(_other), do: {:error, "invalid_oid"}

  def datetime(nil), do: nil
  def datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def datetime(_other), do: nil

  def user(nil), do: nil
  def user(%Ecto.Association.NotLoaded{}), do: nil

  def user(%User{id: id, login: login, name: name}),
    do: %{"id" => id, "login" => login, "name" => name}

  def user(%{login: login} = map), do: %{"login" => login, "name" => Map.get(map, :name)}

  def git_author(nil), do: nil

  def git_author(%{} = author) do
    %{
      "name" => Map.get(author, :name),
      "email" => Map.get(author, :email),
      "timestamp" => datetime(Map.get(author, :timestamp))
    }
  end

  def repo(%Repo{} = repo) do
    %{
      "id" => repo.id,
      "owner" => repo.owner_login,
      "name" => repo.name,
      "description" => repo.description,
      "public" => repo.public,
      "default_branch" => repo.default_branch,
      "pushed_at" => datetime(repo.pushed_at)
    }
  end

  def issue(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "number" => issue.number,
      "title" => issue.title,
      "status" => issue.status,
      "author" => user(issue.author),
      "labels" => label_names(issue.labels),
      "body" => comment_body(issue.comment),
      "created_at" => datetime(issue.inserted_at)
    }
  end

  def comment(%Comment{} = comment) do
    %{
      "id" => comment.id,
      "body" => comment.body,
      "author" => user(comment.author),
      "created_at" => datetime(comment.inserted_at)
    }
  end

  @doc "A compact issue reference (`number`, `title`, `status`) for mutation results."
  def issue_ref(%Issue{} = issue),
    do: %{
      "id" => issue.id,
      "number" => issue.number,
      "title" => issue.title,
      "status" => issue.status
    }

  def release(%Release{} = release) do
    %{
      "id" => release.id,
      "title" => release.title,
      "description" => release.description,
      "release_type" => release.release_type,
      "tag_version" => release.tag_version,
      "revision" => release.revision,
      "author" => user(release.author),
      "created_at" => datetime(release.inserted_at)
    }
  end

  def tree_entry(%GitTreeEntry{} = entry) do
    %{
      "name" => entry.name,
      "type" => to_string(entry.type),
      "oid" => oid(entry.oid),
      "mode" => Integer.to_string(entry.mode, 8)
    }
  end

  @doc """
  A compact AI coding-agent checkpoint summary (`GitGud.Checkpoints`).

  The raw `metadata.json` is carried through as `metadata` when present, which is
  only the case for a single checkpoint read with `GitGud.Checkpoints.get/2`.
  """
  def checkpoint(%{} = checkpoint) do
    %{
      "id" => checkpoint[:id],
      "ref" => checkpoint[:ref],
      "source" => checkpoint_source(checkpoint[:source]),
      "oid" => checkpoint[:oid],
      "branch" => checkpoint[:branch],
      "strategy" => checkpoint[:strategy],
      "checkpoints_count" => checkpoint[:checkpoints_count],
      "files_touched" => checkpoint[:files_touched] || [],
      "session_count" => checkpoint[:session_count] || 0,
      "token_usage" => checkpoint[:token_usage],
      "commit_sha" => checkpoint[:commit_sha],
      "committed_at" => datetime(checkpoint[:committed_at])
    }
    |> put_metadata(checkpoint)
  end

  @doc """
  A `GitGud.Checkpoints` search/provenance match (`%{checkpoint:, matched:, score:}`).
  """
  def checkpoint_match(%{checkpoint: checkpoint, matched: matched, score: score}) do
    checkpoint
    |> checkpoint()
    |> Map.put("matched", matched)
    |> Map.put("score", score)
  end

  def ref(%GitRef{} = ref),
    do: %{"name" => ref.name, "oid" => oid(ref.oid), "type" => to_string(ref.type)}

  def ref(%GitTag{} = tag), do: %{"name" => tag.name, "oid" => oid(tag.oid), "type" => "tag"}
  def ref(%{name: name, oid: ref_oid}), do: %{"name" => name, "oid" => oid(ref_oid)}

  #
  # Write helpers
  #

  @doc "Requires that the user has a verified primary email (mirrors the write path in the web UI)."
  def ensure_verified(user) do
    if User.verified?(user), do: :ok, else: {:error, :forbidden}
  end

  @doc """
  Loads `owner/name` and the issue `number` in one step.

  Returns `{:ok, repo, issue}`. `opts` may carry `preload:` (issue preloads,
  default `[:comment, :labels]`) and `repo:` (extra `RepoQuery.user_repo/3`
  options, e.g. `[preload: [:issue_labels]]`) so callers can resolve label names.
  """
  def fetch_issue(user, params, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:comment, :labels])
    repo_opts = Keyword.get(opts, :repo, [])

    with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name], repo_opts) do
      case IssueQuery.repo_issue(repo, params[:number], preload: preload) do
        nil -> {:error, :not_found}
        issue -> {:ok, repo, issue}
      end
    end
  end

  @doc """
  Resolves a list of label `names` to the repository's `GitGud.IssueLabel` structs.

  Returns `{:error, "label_not_found: <name>"}` for the first unknown label. The
  repository's `:issue_labels` association must be preloaded.
  """
  def resolve_labels(repo, names) do
    available =
      case repo.issue_labels do
        %Ecto.Association.NotLoaded{} -> []
        labels when is_list(labels) -> labels
      end

    Enum.reduce_while(names, [], fn name, acc ->
      case Enum.find(available, &(&1.name == name)) do
        nil -> {:halt, {:error, "label_not_found: #{name}"}}
        %IssueLabel{} = label -> {:cont, [label | acc]}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      labels -> {:ok, Enum.reverse(labels)}
    end
  end

  @doc "Turns an `Ecto.Changeset` into a plain `field => [messages]` map for tool output."
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  def changeset_errors(other), do: inspect(other)

  #
  # Helpers
  #

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(%{message: message}) when is_binary(message), do: message
  defp reason_string(%{message: message}) when is_list(message), do: Enum.join(message, ", ")
  defp reason_string(reason), do: inspect(reason)

  defp label_names(%Ecto.Association.NotLoaded{}), do: []
  defp label_names(labels) when is_list(labels), do: Enum.map(labels, & &1.name)
  defp label_names(_other), do: []

  defp comment_body(%Ecto.Association.NotLoaded{}), do: nil
  defp comment_body(%Comment{body: body}), do: body
  defp comment_body(_other), do: nil

  defp checkpoint_source(nil), do: nil
  defp checkpoint_source(source) when is_atom(source), do: Atom.to_string(source)
  defp checkpoint_source(source) when is_binary(source), do: source
  defp checkpoint_source(_other), do: nil

  defp put_metadata(serialized, %{metadata: metadata}),
    do: Map.put(serialized, "metadata", metadata)

  defp put_metadata(serialized, _checkpoint), do: serialized
end
