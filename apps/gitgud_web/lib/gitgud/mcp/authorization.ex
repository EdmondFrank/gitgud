defmodule GitGud.MCP.Authorization do
  @moduledoc """
  Authorization helpers for MCP tools.

  Two gates apply to every tool call (see `guides/MCP.md` §9):

    1. **Resource gate** — the authenticated user must satisfy
       `GitGud.Authorization.authorized?/3` for the target resource.
    2. **Scope gate** — a personal access token must carry the scope required by
       the invoked tool (`require_scope/2`); session/bearer credentials are
       treated as unrestricted.

  This module implements both gates for repositories: repositories are resolved
  through `GitGud.RepoQuery.user_repo/3` with a `:viewer`, so a repository the
  caller cannot see is reported as `:not_found` (no existence leak); a resolved
  repository is still checked against the `:pull` policy.
  """

  alias GitGud.Authorization
  alias GitGud.PersonalAccessToken
  alias GitGud.Repo
  alias GitGud.RepoQuery
  alias GitGud.User

  @type reason :: :not_found | :forbidden | :insufficient_scope | term

  # Maps every registered MCP tool to the scope a personal access token must
  # carry to invoke it: a single scope, or a list of scopes of which *all* are
  # required. Tools absent from the map are unrestricted. Keep in sync with
  # `GitGud.MCP.Server`.
  @tool_scopes %{
    "whoami" => "user:read",
    "search_repositories" => "repo:read",
    "get_repository" => "repo:read",
    "list_branches" => "repo:read",
    "list_tags" => "repo:read",
    "get_tree" => "repo:read",
    "read_file" => "repo:read",
    "get_commit" => "repo:read",
    "list_releases" => "repo:read",
    "search" => ["repo:read", "user:read"],
    "list_issues" => "issue:read",
    "get_issue" => "issue:read",
    "list_issue_comments" => "issue:read",
    "create_issue" => "issue:write",
    "comment_on_issue" => "issue:write",
    "update_issue_title" => "issue:write",
    "update_issue_labels" => "issue:write",
    "close_issue" => "issue:write",
    "reopen_issue" => "issue:write",
    "update_comment" => "issue:write",
    "delete_comment" => "issue:write",
    "create_commit_line_review_comment" => "review:write"
  }

  @doc """
  Returns all scopes a personal access token can be granted.
  """
  @spec all_scopes :: [binary]
  def all_scopes, do: PersonalAccessToken.scopes()

  @doc """
  Returns the scope(s) required to invoke `tool`, or `nil` when unrestricted.

  A list means *every* scope in it is required.
  """
  @spec required_scope(binary) :: binary | [binary] | nil
  def required_scope(tool), do: Map.get(@tool_scopes, tool)

  @doc """
  Returns `true` when `scopes` grants `tool`.

  A `nil` `scopes` (session/bearer authentication) is treated as unrestricted.
  """
  @spec visible_tool?([binary] | nil, binary) :: boolean
  def visible_tool?(nil, _tool), do: true

  def visible_tool?(scopes, tool) when is_list(scopes) do
    case required_scope(tool) do
      nil -> true
      required when is_list(required) -> Enum.all?(required, &(&1 in scopes))
      scope -> scope in scopes
    end
  end

  @doc """
  Authorizes an invocation of `tool` for the given `scopes`.
  """
  @spec authorize_tool([binary] | nil, binary) :: :ok | {:error, :insufficient_scope}
  def authorize_tool(scopes, tool) do
    if visible_tool?(scopes, tool), do: :ok, else: {:error, :insufficient_scope}
  end

  @doc """
  Loads `owner/name` for `user` and enforces the `:pull` policy.

  Returns `{:ok, repo}` when the repository is visible and readable by `user`,
  `{:error, :not_found}` when it does not exist or is not visible, and
  `{:error, :forbidden}` when it is visible but not readable.
  """
  @spec fetch_repo(User.t() | nil, binary, binary) :: {:ok, Repo.t()} | {:error, reason}
  def fetch_repo(user, owner, name) when is_binary(owner) and is_binary(name) do
    case RepoQuery.user_repo(owner, name, viewer: user) do
      %Repo{} = repo -> enforce(user, repo, :pull)
      _other -> {:error, :not_found}
    end
  end

  def fetch_repo(_user, _owner, _name), do: {:error, :not_found}

  @doc """
  Like `fetch_repo/3`, but forwards extra `RepoQuery.user_repo/3` options (e.g.
  `preload: [:issue_labels]`) so write tools can resolve associations.
  """
  @spec fetch_repo(User.t() | nil, binary, binary, keyword) :: {:ok, Repo.t()} | {:error, reason}
  def fetch_repo(user, owner, name, opts) when is_binary(owner) and is_binary(name) do
    case RepoQuery.user_repo(owner, name, Keyword.merge([viewer: user], opts)) do
      %Repo{} = repo -> enforce(user, repo, :pull)
      _other -> {:error, :not_found}
    end
  end

  def fetch_repo(_user, _owner, _name, _opts), do: {:error, :not_found}

  @doc """
  Enforces the authorization policy for `action` on `resource`.
  """
  @spec enforce(User.t() | nil, term, atom) :: {:ok, term} | {:error, :forbidden}
  def enforce(user, resource, action), do: Authorization.enforce_policy(user, resource, action)
end
