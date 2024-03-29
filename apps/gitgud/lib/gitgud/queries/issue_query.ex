defmodule GitGud.IssueQuery do
  @moduledoc """
  Conveniences for issue related queries.
  """

  @behaviour GitGud.DBQueryable

  @queryable_status [:open, :close]

  alias GitGud.DB
  alias GitGud.DBQueryable

  alias GitGud.User
  alias GitGud.Repo
  alias GitGud.RepoQuery
  alias GitGud.Issue
  alias GitGud.Comment

  import Ecto.Query

  @doc """
  Returns a repository issue for the given `id`.
  """
  @spec by_id(pos_integer, keyword) :: Issue.t | nil
  def by_id(id, opts \\ []) do
    DB.one(DBQueryable.query({__MODULE__, :issue_query}, id, opts))
  end

  @doc """
  Returns a repository issue for the given `number`.
  """
  @spec repo_issue(Repo.t | pos_integer, pos_integer, keyword) :: Issue.t | nil
  def repo_issue(repo, number, opts \\ [])
  def repo_issue(%Repo{id: repo_id}, number, opts), do: repo_issue(repo_id, number, opts)
  def repo_issue(repo_id, number, opts) do
    DB.one(DBQueryable.query({__MODULE__, :repo_issue_query}, [repo_id, number], opts))
  end

  @doc """
  Returns all issues for the given `repo`.
  """
  @spec repo_issues(Repo.t | pos_integer, keyword) :: [Issue.t]
  def repo_issues(repo, opts \\ [])
  def repo_issues(%Repo{id: repo_id}, opts), do: repo_issues(repo_id, opts)
  def repo_issues(repo_id, opts) do
    {params, opts} = Keyword.split(opts, [:numbers, :status, :labels, :search])
    DB.all(DBQueryable.query({__MODULE__, :repo_issues_query}, [repo_id, Map.new(params)], opts))
  end

  @doc """
  Returns all issues with number of replies for the given `repo`.
  """
  @spec repo_issues_with_reply_count(Repo.t | pos_integer, keyword) :: [{Issue.t, pos_integer}]
  def repo_issues_with_reply_count(repo, opts \\ [])
  def repo_issues_with_reply_count(%Repo{id: repo_id}, opts), do: repo_issues_with_reply_count(repo_id, opts)
  def repo_issues_with_reply_count(repo_id, opts) do
    {params, opts} = Keyword.split(opts, [:numbers, :status, :labels, :search])
    DB.all(DBQueryable.query({__MODULE__, :repo_issues_with_reply_count_query}, [repo_id, Map.new(params)], opts))
  end

  @doc """
  Returns the number of issues for the given `repo`.
  """
  @spec count_repo_issues(Repo.t | pos_integer, keyword) :: non_neg_integer()
  @spec count_repo_issues([Repo.t | pos_integer], keyword) :: %{pos_integer => non_neg_integer}
  def count_repo_issues(repo, opts \\ [])
  def count_repo_issues(repos, opts) when is_list(repos) do
    repo_ids =
      Enum.map(repos, fn
        %Repo{id: repo_id} ->
          repo_id
        repo_id when is_integer(repo_id) ->
          repo_id
      end)
    count_map =
      query(:count_repo_issues_query, [repo_ids, Keyword.get(opts, :status, @queryable_status)])
      |> DB.all()
      |> Map.new()
    Map.new(repo_ids, &{&1, Map.get(count_map, &1, 0)})
  end

  def count_repo_issues(%Repo{id: repo_id}, opts), do: count_repo_issues(repo_id, opts)
  def count_repo_issues(repo_id, opts) do
    status = Keyword.get(opts, :status, @queryable_status)
    labels = Keyword.get(opts, :labels, [])
    DB.one(query(:count_repo_issues_query, [repo_id, status, labels]))
  end

  @doc """
  Returns the number of issues grouped by status for the given `repo`.
  """
  @spec count_repo_issues_by_status(Repo.t | pos_integer, keyword) :: %{atom => non_neg_integer}
  def count_repo_issues_by_status(repo, opts \\ [])
  def count_repo_issues_by_status(%Repo{id: repo_id}, opts), do: count_repo_issues_by_status(repo_id, opts)
  def count_repo_issues_by_status(repo_id, opts) do
      labels = Keyword.get(opts, :labels, [])
      query(:count_repo_issues_by_status_query, [repo_id, @queryable_status, labels])
      |> DB.all()
      |> Map.new(fn {status, count} -> {String.to_atom(status), count} end)
      |> Map.put_new(:open, 0)
      |> Map.put_new(:close, 0)
  end

  @doc """
  Returns a list of permissions for the given `issue` and `user`.
  """
  @spec permissions(Issue.t, User.t | nil, [atom] | nil):: [atom]
  def permissions(%Issue{} = issue, user, repo_perms \\ nil) do
    repo_perms = repo_perms || repo_perms(issue, user)
    cond do
      :admin in repo_perms ->
        [:comment, :close, :reopen, :edit_title, :edit_labels]
      User.verified?(user) && issue.author_id == user.id ->
        [:comment, :close, :reopen]
      User.verified?(user) ->
        [:comment]
      true ->
        []
    end
  end

  #
  # Callbacks
  #

  @impl true
  def query(:issue_query, [id]) when is_integer(id) do
    from(i in Issue, as: :issue, where: i.id == ^id)
  end

  def query(:repo_issue_query, [repo_id, number]) when is_integer(repo_id) and is_integer(number) do
    from(i in Issue, as: :issue, where: i.repo_id == ^repo_id and i.number == ^number)
  end

  def query(:repo_issues_query, [repo_id]), do: query(:repo_issues_query, [repo_id, @queryable_status])

  def query(:repo_issues_query, [repo_id, %{numbers: numbers}]) do
    query(:repo_issues_query, [repo_id, numbers])
  end

  def query(:repo_issues_query, [repo_id, params]) when is_integer(repo_id) and is_map(params) do
    Enum.reduce(Map.get(params, :search, []), query(:repo_issues_query, [repo_id, Map.get(params, :status, @queryable_status), Map.get(params, :labels, [])]), fn search_term, query ->
      where(query, [issue: i], ilike(i.title, ^"%#{search_term}%"))
    end)
  end

  def query(:repo_issues_query, [repo_ids, status]) when is_list(repo_ids) and status in @queryable_status do
    from(i in Issue, as: :issue, where: i.repo_id in ^repo_ids and i.status == ^to_string(status))
  end

  def query(:repo_issues_query, [repo_id, status]) when is_integer(repo_id) and status in @queryable_status do
    from(i in Issue, as: :issue, where: i.repo_id == ^repo_id and i.status == ^to_string(status))
  end

  def query(:repo_issues_query, [repo_ids, [status]]) when is_list(repo_ids) and status in @queryable_status do
    from(i in Issue, as: :issue, where: i.repo_id in ^repo_ids and i.status == ^to_string(status))
  end

  def query(:repo_issues_query, [repo_id, [status]]) when is_integer(repo_id) and status in @queryable_status do
    from(i in Issue, as: :issue, where: i.repo_id == ^repo_id and i.status == ^to_string(status))
  end

  def query(:repo_issues_query, [repo_ids, params]) when is_list(repo_ids) and is_list(params) do
    cond do
      Enum.empty?(params -- @queryable_status) ->
        from(i in Issue, as: :issue, where: i.repo_id in ^repo_ids)
      Enum.all?(params, &(&1 in @queryable_status)) ->
        status = Enum.map(params, &to_string/1)
        from(i in Issue, as: :issue, where: i.repo_id in ^repo_ids and i.status in ^status)
    end
  end

  def query(:repo_issues_query, [repo_id, params]) when is_integer(repo_id) and is_list(params) do
    cond do
      Enum.empty?(params -- @queryable_status) ->
        from(i in Issue, as: :issue, where: i.repo_id == ^repo_id)
      Enum.all?(params, &(&1 in @queryable_status)) ->
        status = Enum.map(params, &to_string/1)
        from(i in Issue, as: :issue, where: i.repo_id == ^repo_id and i.status in ^status)
      Enum.all?(params, &is_integer/1) ->
        from(i in Issue, as: :issue, where: i.repo_id == ^repo_id and i.number in ^params)
    end
  end

  def query(:repo_issues_query, [repo_id, status, []]) do
    query(:repo_issues_query, [repo_id, status])
  end

  def query(:repo_issues_query, [repo_id, status, labels]) do
    query(:repo_issues_query, [repo_id, status])
    |> join(:inner, [issue: i], l in assoc(i, :labels), as: :labels)
    |> group_by([issue: i], i.id)
    |> having([issue: i, labels: l], fragment("array_agg(?) @> (?)::varchar[]", l.name, ^labels))
  end

  def query(:repo_issues_with_reply_count_query, args) do
    query(:repo_issues_query, args)
    |> join(:left, [issue: i], c in assoc(i, :replies), as: :replies)
    |> group_by([issue: i], i.id)
    |> select([issue: i, replies: c], {i, count(c.id, :distinct)})
  end

  def query(:count_repo_issues_query, [repo_ids|_] = args) when is_list(repo_ids) do
    query(:repo_issues_query, args)
    |> group_by([issue: i], i.repo_id)
    |> select([issue: i], {i.repo_id, count(i.id)})
  end

  def query(:count_repo_issues_query, args) do
    select(query(:repo_issues_query, args), [issue: e], count())
  end

  def query(:count_repo_issues_by_status_query, args) do
    query(:repo_issues_query, args)
    |> group_by([issue: i], i.status)
    |> select([issue: i], {i.status, count(i.id)})
  end

  def query(:comments_query, [%Issue{id: issue_id} = _issue]), do: query(:comments_query, [issue_id])
  def query(:comments_query, [issue_id]) when is_integer(issue_id) do
    from c in Comment, as: :comment, join: t in "issues_comments", on: t.comment_id == c.id, where: t.thread_id == ^issue_id
  end

  @impl true
  def alter_query(query,  _viewer), do: query

  @impl true
  def preload_query(query, preloads, _viewer), do: preload(query, [], ^preloads)

  defp repo_perms(%Issue{repo: %Repo{} = repo}, user), do: RepoQuery.permissions(repo, user)
  defp repo_perms(%Issue{repo_id: repo_id}, user), do: RepoQuery.permissions(repo_id, user)
end
