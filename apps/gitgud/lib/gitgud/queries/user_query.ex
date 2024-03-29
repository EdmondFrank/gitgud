defmodule GitGud.UserQuery do
  @moduledoc """
  Conveniences for user related queries.
  """

  @behaviour GitGud.DBQueryable

  alias GitGud.DB
  alias GitGud.DBQueryable

  alias GitGud.Email
  alias GitGud.User
  alias GitGud.Maintainer

  import Ecto.Query

  @doc """
  Returns a user for the given `id`.
  """
  @spec by_id(pos_integer, keyword) :: User.t | nil
  @spec by_id([pos_integer], keyword) :: [User.t]
  def by_id(id, opts \\ [])
  def by_id(ids, opts) when is_list(ids) do
    DB.all(DBQueryable.query({__MODULE__, :users_query}, [ids], opts))
  end

  def by_id(id, opts) do
    DB.one(DBQueryable.query({__MODULE__, :user_query}, id, opts))
  end

  @doc """
  Returns a user for the given `login`.
  """
  @spec by_login(binary, keyword) :: User.t | nil
  @spec by_login([binary], keyword) :: [User.t]
  def by_login(login, opts \\ [])
  def by_login(logins, opts) when is_list(logins) do
    DB.all(DBQueryable.query({__MODULE__, :users_query}, [:login, logins], opts))
  end

  def by_login(login, opts) do
    DB.one(DBQueryable.query({__MODULE__, :user_query}, [:login, login], opts))
  end

  @doc """
  Returns a user for the given `email`.
  """
  @spec by_email(binary, keyword) :: User.t | nil
  @spec by_email([binary], keyword) :: [User.t]
  def by_email(email, opts \\ [])
  def by_email(emails, opts) when is_list(emails) do
    DB.all(DBQueryable.query({__MODULE__, :users_query}, [:email, emails], opts))
  end

  def by_email(email, opts) do
    DB.one(DBQueryable.query({__MODULE__, :user_query}, [:email, email], opts))
  end

  @doc """
  Returns a user for the given SSH key `fingerprint`.
  """
  @spec by_ssh_key(binary, keyword) :: User.t | nil
  def by_ssh_key(fingerprint, opts \\ []) do
    DB.one(DBQueryable.query({__MODULE__, :user_ssh_key_query}, fingerprint, opts))
  end

  @doc """
  Returns a user for the given authentication `provider` and `id`.
  """
  @spec by_oauth(binary, binary, keyword) :: User.t | nil
  def by_oauth(provider, id, opts \\ []) do
    DB.one(DBQueryable.query({__MODULE__, :user_oauth_query}, [provider, id], opts))
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
  Returns users count of entire site.
  """
  @spec count(keyword) :: non_neg_integer()
  def count(opts \\ []) do
    DB.one(DBQueryable.query({__MODULE__, :count_users_query}, [], opts))
  end

  @doc """
  Returns first user inserted_at.
  """
  @spec first_at() :: NaiveDateTime
  def first_at() do
    DB.one(query(:users_query_first)).inserted_at
  end

  #
  # Callbacks
  #

  @impl true
  def query(:user_query, [id]) when is_integer(id), do: query(:user_query, [:id, id])

  def query(:user_query, [:email = _key, val]) do
    from(u in User, as: :user, join: e in assoc(u, :emails), where: e.verified == true and e.address == ^val)
  end

  def query(:user_query, [key, val]) do
    from(u in User, as: :user, where: ^List.wrap({key, val}))
  end

  def query(:user_ssh_key_query, [fingerprint]) do
    from(u in User, as: :user, join: s in assoc(u, :ssh_keys), where: s.fingerprint == ^fingerprint)
  end

  def query(:user_oauth_query, [provider, id]) do
    from(u in User, as: :user,
      join: a in assoc(u, :account),
      join: p in assoc(a, :oauth2_providers), where: p.provider == ^provider and p.provider_id == ^id,
      preload: [account: a])
  end

  def query(:users_query, [ids]) when is_list(ids) do
    from(u in User, as: :user, where: u.id in ^ids)
  end

  def query(:users_query, [:login = _key, vals]) when is_list(vals) do
    from(u in User, as: :user, where: u.login in ^vals)
  end

  def query(:users_query, [:email = _key, vals]) when is_list(vals) do
    from(u in User, as: :user, join: e in assoc(u, :emails), where: e.verified == true and e.address in ^vals)
  end

  def query(:search_query, [input, threshold]) do
    from(u in User, as: :user, where: fragment("similarity(?, ?) > ?", u.login, ^input, ^threshold) and not is_nil(u.primary_email_id), order_by: fragment("similarity(?, ?) DESC", u.login, ^input))
  end

  def query(:count_users_query, _opts) do
    from(u in User, select: count(u.id))
  end

  def query(:users_query_first) do
    from(u in User, as: :user, join: e in assoc(u, :emails), where: e.verified == true, order_by: [asc: :inserted_at], limit: 1)
  end

  @impl true
  def alter_query(query, _viewer), do: query

  @impl true
  def preload_query(query, [], _viewer), do: query

  @impl true
  def preload_query(query, [preload|tail], viewer) do
    query
    |> join_preload(preload, viewer)
    |> preload_query(tail, viewer)
  end

  #
  # Helpers
  #

  defp join_preload(query, :emails, _viewer) do
    query
    |> join(:left, [user: u], e in assoc(u, :emails), as: :emails)
    |> preload([emails: e], [emails: e])
  end

  defp join_preload(query, :primary_email, _viewer) do
    query
    |> join(:left, [user: u], e in Email, on: e.id == u.primary_email_id, as: :primary_email)
    |> preload([primary_email: e], [primary_email: e])
  end

  defp join_preload(query, :public_email, _viewer) do
    query
    |> join(:left, [user: u], e in Email, on: e.id == u.public_email_id, as: :public_email)
    |> preload([public_email: e], [public_email: e])
  end

  defp join_preload(query, :repos, %User{} = viewer) do
    query
    |> join(:left, [user: u], m in Maintainer, on: m.user_id == ^viewer.id, as: :maintainer)
    |> join(:left, [user: u, maintainer: m], r in assoc(u, :repos), on: (r.public == true and not is_nil(r.pushed_at)) or r.owner_id == ^viewer.id or m.repo_id == r.id, as: :repos)
    |> preload([repos: r], [repos: r])
  end

  defp join_preload(query, :repos, nil) do
    query
    |> join(:left, [user: u], r in assoc(u, :repos), on: r.public == true and not is_nil(r.pushed_at), as: :repos)
    |> preload([repos: r], [repos: r])
  end

  defp join_preload(query, :repos, _viewer) do
    query
    |> join(:left, [user: u], r in assoc(u, :repos), as: :repos)
    |> preload([repos: r], [repos: r])
  end


  defp join_preload(query, {parent, _children} = preload, viewer) do
    query
    |> join_preload(parent, viewer)
    |> preload(^preload)
  end

  defp join_preload(query, preload, _viewer) do
    preload(query, ^preload)
  end
end
