defmodule GitGud.RepoQuery do
  @moduledoc """
  Conveniences for repository related queries.
  """

  @behaviour GitGud.DBQueryable

  alias GitGud.DB
  alias GitGud.DBQueryable

  alias GitGud.User
  alias GitGud.Repo
  alias GitGud.Maintainer

  import Ecto.Query

  @type user_param :: User.t | binary | pos_integer

  @doc """
  Returns a repository for the given `id`.
  """
  @spec by_id(pos_integer, keyword) :: Repo.t | nil
  @spec by_id([pos_integer], keyword) :: [Repo.t]
  def by_id(id, opts \\ [])
  def by_id(ids, opts) when is_list(ids) do
    DB.all(DBQueryable.query({__MODULE__, :repo_query}, [ids], opts))
  end

  def by_id(id, opts) do
    DB.one(DBQueryable.query({__MODULE__, :repo_query}, id, opts))
  end

  @doc """
  Returns a list of repositories for the given `user`.
  """
  @spec user_repos(user_param, keyword) :: [Repo.t]
  @spec user_repos([user_param], keyword) :: [Repo.t]
  def user_repos(user, opts \\ [])
  def user_repos(users, opts) when is_list(users) do
    DB.all(DBQueryable.query({__MODULE__, :user_repos_query}, [users], opts))
  end

  def user_repos(user, opts) do
    DB.all(DBQueryable.query({__MODULE__, :user_repos_query}, user, opts))
  end

  @doc """
  Returns a single repository for the given `user` and `name`.
  """
  @spec user_repo(user_param, binary, keyword) :: Repo.t | nil
  def user_repo(user, name, opts \\ [])
  def user_repo(user, name, opts) do
    DB.one(DBQueryable.query({__MODULE__, :user_repo_query}, [user, name], opts))
  end

  @doc """
  Returns a repository for the given `path`.
  """
  @spec by_path(Path.t, keyword) :: Repo.t | nil
  def by_path(path, opts \\ []) do
    path = Path.relative_to(path, Application.fetch_env!(:gitgud, :git_root))
    case Path.split(path) do
      [login, name] ->
        user_repo(login, name, opts)
      _path ->
        nil
    end
  end

  @doc """
  Returns the total number of repositories.
  """
  @spec count_total() :: non_neg_integer
  def count_total do
    DB.one(query(:count_query, [:total]))
  end

  @doc """
  Returns the number of public repositories.
  """
  @spec count_public() :: non_neg_integer
  def count_public do
    DB.one(query(:count_query, [:public]))
  end

  @doc """
  Returns the number of private repositories.
  """
  @spec count_private() :: non_neg_integer
  def count_private do
    DB.one(query(:count_query, [:private]))
  end

  @doc """
  Returns a list of users matching the given `input`.
  """
  @spec search(binary, keyword) :: [User.t]
  def search(input, opts \\ []) do
    {threshold, opts} = Keyword.pop(opts, :similarity, 0.3)
    DB.all(DBQueryable.query({__MODULE__, :search_query}, [input, threshold], opts))
  end

  @doc """
  Returns a list of associated `GitGud.Maintainer` for the given `repo`.
  """
  @spec maintainers(Repo.t | pos_integer) :: [Maintainer.t]
  def maintainers(%Repo{id: repo_id} = _repo), do: maintainers(repo_id)
  def maintainers(repo_id) do
    DB.all(query(:maintainers_query, [repo_id]))
  end

  @doc """
  Returns a single `GitGud.Maintainer` for the given `repo` and `user`.
  """
  @spec maintainer(Repo.t | pos_integer, User.t) :: Maintainer.t | nil
  def maintainer(_repo, nil = _user), do: nil
  def maintainer(%Repo{id: repo_id}, %User{} = user), do: maintainer(repo_id, user)
  def maintainer(repo_id, %User{id: user_id} = user) do
    if maintainer = DB.one(query(:maintainer_query, [repo_id, user_id])) do
      struct(maintainer, user: user)
    end
  end

  @doc """
  Returns a list of permissions for the given `repo` and `user`.
  """
  @spec permissions(Repo.t, User.t | nil):: [atom]
  def permissions(repo, user)
  def permissions(%Repo{public: true, pushed_at: %NaiveDateTime{}}, nil), do: [:read]
  def permissions(%Repo{}, nil), do: []
  def permissions(%Repo{owner_id: user_id}, %User{id: user_id}), do: [:read, :write, :admin]
  def permissions(%Repo{} = repo, %User{} = user) do
    if maintainer = maintainer(repo, user) do
      case maintainer.permission do
        "read" -> [:read]
        "write" -> [:read, :write]
        "admin" -> [:read, :write, :admin]
      end
    end || []
  end

  #
  # Callbacks
  #

  @impl true
  def query(:repo_query, [id]) when is_list(id) do
    from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: r.id in ^id, preload: [owner: u])
  end

  def query(:repo_query, [id]) when is_integer(id) do
    from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: r.id == ^id, preload: [owner: u])
  end

  def query(:user_repo_query, [user, name]) do
    where(query(:user_repos_query, [user]), name: ^name)
  end

  def query(:user_repos_query, [%User{id: user_id} = _user]), do: query(:user_repos_query, [user_id])
  def query(:user_repos_query, [login]) when is_binary(login) do
    from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: u.login == ^login, preload: [owner: u])
  end

  def query(:user_repos_query, [user_id]) when is_integer(user_id) do
    from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: u.id == ^user_id, preload: [owner: u])
  end

  def query(:user_repos_query, [users]) when is_list(users) do
    cond do
      Enum.all?(users, &is_map/1) ->
        user_ids = Enum.map(users, &Map.fetch!(&1, :id))
        from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: u.id in ^user_ids, preload: [owner: u])
      Enum.all?(users, &is_integer/1) ->
        from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: u.id in ^users, preload: [owner: u])
      Enum.all?(users, &is_binary/1) ->
        from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: u.login in ^users, preload: [owner: u])
    end
  end

  def query(:search_query, [input, threshold]) do
    from(r in Repo, as: :repo, join: u in assoc(r, :owner), where: fragment("similarity(?, ?) > ?", r.name, ^input, ^threshold), order_by: fragment("similarity(?, ?) DESC", r.name, ^input), preload: [owner: u])
  end

  def query(:maintainers_query, [repo_id]) do
    from(m in Maintainer, join: u in assoc(m, :user), where: m.repo_id == ^repo_id, preload: [user: u])
  end

  def query(:maintainer_query, [repo_id, user_id]) do
    from(m in Maintainer, where: m.repo_id == ^repo_id and m.user_id == ^user_id)
  end

  def query(:count_query, [:total]) do
    from(r in Repo, as: :repo, select: count(r.id))
  end

  def query(:count_query, [:public]) do
    from(r in Repo, as: :repo, where: r.public == true, select: count(r.id))
  end

  def query(:count_query, [:private]) do
    from(r in Repo, as: :repo, where: r.public == false, select: count(r.id))
  end


  @impl true
  def alter_query(query, preloads, nil) do
    query
    |> where([repo: r], r.public == true and not is_nil(r.pushed_at))
    |> preload([], ^preloads)
  end

  @impl true
  def alter_query(query, preloads, viewer) do
    query
    |> join(:left, [repo: r], m in Maintainer, on: r.id == m.repo_id, as: :maintainer)
    |> where([repo: r, maintainer: m], (r.public == true and not is_nil(r.pushed_at)) or r.owner_id == ^viewer.id or m.user_id == ^viewer.id)
    |> preload([], ^preloads)
  end
end
