defmodule GitGud.Repo do
  @moduledoc """
  Repository schema and helper functions.

  A repository contains the content for a project.
  """

  use Ecto.Schema

  alias Ecto.Multi

  alias GitRekt.GitAgent
  alias GitRekt.GitRef
  alias GitRekt.GitTag
  alias GitRekt.GitRepo

  alias GitGud.DB
  alias GitGud.Issue
  alias GitGud.IssueLabel
  alias GitGud.User
  alias GitGud.RepoPool
  alias GitGud.RepoQuery
  alias GitGud.RepoStorage
  alias GitGud.Maintainer

  import Ecto.Changeset

  schema "repositories" do
    belongs_to :owner, User
    field :owner_login, :string
    field :name, :string
    field :public, :boolean, default: true
    field :default_branch, :string, default: "main"
    field :volume, :string, autogenerate: {RepoStorage, :volume, []}
    field :description, :string
    has_many :issue_labels, IssueLabel, on_replace: :delete
    has_many :issues, Issue
    many_to_many :maintainers, User, join_through: Maintainer, on_replace: :delete
    many_to_many :contributors, User, join_through: "repositories_contributors", on_replace: :delete
    timestamps()
    field :pushed_at, :naive_datetime
  end

  @type t :: %__MODULE__{
    id: pos_integer,
    owner_id: pos_integer,
    owner: User.t,
    name: binary,
    public: boolean,
    default_branch: binary,
    volume: binary,
    description: binary,
    maintainers: [User.t],
    contributors: [User.t],
    inserted_at: NaiveDateTime.t,
    updated_at: NaiveDateTime.t,
    pushed_at: NaiveDateTime.t,
  }

  @issue_labels %{
    "bug" => "ee0701",
    "question" => "cc317c",
    "duplicate" => "cccccc",
    "help wanted" => "33aa3f",
    "invalid" => "e6e6e6"
  }

  @earliest ~N[1970-01-01 00:00:00]

  @doc """
  Return earliest time instead of nil.
  """
  def earliest, do: @earliest

  @doc """
  Creates and initialize a new repository.

  ```elixir
  {:ok, repo} = GitGud.Repo.create(
    user,
    name: "gitgud",
    description: "GitHub clone entirely written in Elixir.",
    public: true
  )
  ```

  This function validates the given `params` using `changeset/2`.

  By default a bare Git repository will be initialized (see `GitGud.RepoStorage.init/2`). If you prefer to
  create a non-bare repository, you can set the `:bare` option to `false`.
  """
  @spec create(User.t, map|keyword, keyword) :: {:ok, t} | {:error, Ecto.Changeset.t | term}
  def create(owner, params, opts \\ []) do
    changeset = changeset(%__MODULE__{owner_id: owner.id, owner_login: owner.login, owner: owner}, Map.new(params))
    multi =
      if Keyword.get(opts, :init, true),
        do: create_and_init_multi(changeset, Keyword.get(opts, :bare, true)),
      else: create_multi(changeset)
    case DB.transaction(multi) do
      {:ok, %{repo: repo, issue_labels: issue_labels}} ->
        {:ok, struct(repo, issue_labels: issue_labels, maintainers: [repo.owner])}
      {:error, :init, reason, _changes} ->
        {:error, reason}
      {:error, _name, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Similar to `create/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(User.t, map|keyword, keyword) :: t
  def create!(owner, params, opts \\ []) do
    case create(owner, params, opts) do
      {:ok, repo} -> repo
      {:error, changeset} -> raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
    end
  end

  @doc """
  Updates the given `repo` with the given `params`.

  ```elixir
  {:ok, repo} = GitGud.Repo.update(repo, description: "Host open-source project without hassle.")
  ```

  This function validates the given `params` using `changeset/2`.
  """
  @spec update(t, map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t | :file.posix}
  def update(%__MODULE__{} = repo, params) do
    case update_and_rename(changeset(repo, Map.new(params))) do
      {:ok, %{repo: repo}} ->
        {:ok, repo}
      {:error, :repo, changeset, _changes} ->
        {:error, changeset}
      {:error, :rename, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Similar to `update/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec update!(t, map|keyword) :: t
  def update!(%__MODULE__{} = repo, params) do
    case update(repo, params) do
      {:ok, repo} ->
        repo
      {:error, %Ecto.Changeset{} = changeset} ->
        raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
      {:error, reason} ->
        raise File.Error, reason: reason, action: "rename directory", path: Path.join(repo.owner_login, repo.name)
    end
  end

  @doc """
  Updates the associated issues labels for the given `repo` with the given `params`.

  ```elixir
  {:ok, repo} = GitGud.Repo.update_issue_labels(repo, issue_labels_params)
  ```

  This function validates the given `params` using `issue_labels_changeset/2`.
  """
  @spec update_issue_labels(t, map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def update_issue_labels(repo, params), do: DB.update(issue_labels_changeset(repo, Map.new(params)))

  @doc """
  Similar to `update_issue_labels/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec update_issue_labels!(t, map|keyword) :: t
  def update_issue_labels!(repo, params), do: DB.update!(issue_labels_changeset(repo, Map.new(params)))

  @doc """
  Adds a new maintainer to the given `repo`.

  ```elixir
  {:ok, maintainer} = GitGud.Repo.add_maintainer(repo, user_id: user.id, permissions: "write")
  ```

  This function validates the given `params` using `GitGud.Maintainer.changeset/2`.
  """
  @spec add_maintainer(t, map|keyword) :: {:ok, Maintainer.t} | {:error, Ecto.Changeset.t}
  def add_maintainer(repo, params) do
    DB.insert(Maintainer.changeset(%Maintainer{repo_id: repo.id}, Map.new(params)))
  end

  @doc """
  Similar to `add_maintainer/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec add_maintainer!(t, map|keyword) :: Maintainer.t
  def add_maintainer!(repo, params) do
    DB.insert!(Maintainer.changeset(%Maintainer{repo_id: repo.id}, Map.new(params)))
  end

  @doc """
  Deletes the given `repo`.

  ```elixir
  {:ok, repo} = GitGud.Repo.delete(repo)
  ```

  Repository associations (maintainers, issues, etc.) and related Git data will automatically be deleted.
  """
  @spec delete(t) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def delete(%__MODULE__{} = repo) do
    case delete_and_cleanup(repo) do
      {:ok, %{repo: repo}} ->
        {:ok, repo}
      {:error, :repo, changeset, _changes} ->
        {:error, changeset}
      {:error, :cleanup, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Similar to `delete!/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec delete!(t) :: t
  def delete!(%__MODULE__{} = repo) do
    case delete(repo) do
      {:ok, repo} -> repo
      {:error, changeset} -> raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
    end
  end

  @doc """
  Returns a changeset for the given `params`.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t
  def changeset(%__MODULE__{} = repo, params \\ %{}) do
    repo
    |> cast(params, [:name, :public, :description, :default_branch, :pushed_at])
    |> validate_required([:name, :default_branch])
    |> validate_format(:name, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_length(:name, min: 3, max: 80)
    |> validate_exclusion(:name, ["repositories", "settings"])
    |> unique_constraint(:name, name: :repositories_owner_id_name_index)
  end

  @doc """
  Returns a changeset for manipulating all associated issue labels at once.
  """
  @spec issue_labels_changeset(t, map) :: Ecto.Changeset.t
  def issue_labels_changeset(%__MODULE__{} = repo, params \\ %{}) when not is_struct(repo.issue_labels, Ecto.Association.NotLoaded) do
    repo
    |> struct(issue_labels: Enum.sort_by(repo.issue_labels, &(&1.id)))
    |> cast(params, [])
    |> cast_assoc(:issue_labels, with: &IssueLabel.changeset/2)
  end

  @doc """
  Returns branches for the given `repo`.
  """
  @spec branches(%__MODULE__{}) :: [tuple] | {:error, term}
  def branches(%__MODULE__{} = repo) do
    with {:ok, agent} <- GitRepo.get_agent(repo),
         {:ok, {head, branches}} <- GitAgent.transaction(agent, &resolve_branches/1) do
      if head_index = Enum.find_index(branches, &match?({^head, _, _}, &1)) do
        Enum.sort_by(List.delete_at(branches, head_index), &elem(&1, 2), {:desc, Date})
      else
        Enum.sort_by(branches, &elem(&1, 2), {:desc, Date})
      end
    end
  end

  @doc """
  Returns tags for the given `repo`.
  """
  @spec tags(%__MODULE__{}) :: [tuple] | {:error, term}
  def tags(%__MODULE__{} = repo) do
    with {:ok, agent} <- GitRepo.get_agent(repo) do
      case GitAgent.transaction(agent, &resolve_tags/1) do
        {:ok, tags} ->
          Enum.sort_by(tags, &elem(&1, 2), {:desc, Date})
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  #
  # Protocols
  #

  defimpl GitRekt.GitRepo do
    def get_agent(repo), do: RepoPool.checkout_monitor(repo)

    def push(repo, _cmds), do: DB.update(change(repo, pushed_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)))
  end

  defimpl GitGud.AuthorizationPolicies do
    def can?(repo, user, action), do: action in RepoQuery.permissions(repo, user)
  end

  #
  # Helpers
  #

  defp create_multi(changeset) do
    Multi.new()
    |> Multi.insert(:repo, changeset)
    |> Multi.run(:maintainer, &create_maintainer/2)
    |> Multi.run(:issue_labels, &create_issue_labels/2)
  end

  defp create_and_init_multi(changeset, bare?) do
    changeset
    |> create_multi()
    |> Multi.run(:init, &init(&1, &2, bare?))
  end

  defp create_maintainer(db, %{repo: repo}) do
    changeset = Maintainer.changeset(%Maintainer{repo_id: repo.id}, %{user_id: repo.owner_id, permission: "admin"})
    db.insert(changeset)
  end

  defp create_issue_labels(db, %{repo: repo}) do
    Enum.reduce_while(@issue_labels, {:ok, []}, fn {name, color}, {:ok, acc} ->
      changeset = IssueLabel.changeset(%IssueLabel{repo_id: repo.id}, %{name: name, color: color})
      case db.insert(changeset) do
        {:ok, label} -> {:cont, {:ok, [label|acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_and_rename(changeset) do
    Multi.new()
    |> Multi.update(:repo, changeset)
    |> Multi.run(:update_head, &update_head(&1, &2, changeset))
    |> Multi.run(:rename, &rename(&1, &2, changeset))
    |> DB.transaction()
  end

  defp delete_and_cleanup(repo) do
    Multi.new()
    |> Multi.delete(:repo, repo)
    |> Multi.run(:cleanup, &cleanup/2)
    |> DB.transaction()
  end

  defp init(_db, %{repo: repo}, bare?) do
    RepoStorage.init(repo, bare?)
  end

  defp rename(_db, %{repo: repo}, changeset) do
    unless get_change(changeset, :name),
      do: {:ok, RepoStorage.workdir(repo)},
    else: RepoStorage.rename(changeset.data, repo)
  end

  defp update_head(_db, %{repo: repo}, changeset) do
    if branch = get_change(changeset, :default_branch) do
      target = "refs/heads/" <> branch
      case GitAgent.reference_create(repo, "HEAD", :symbolic, target, force: true) do
        :ok ->
          {:ok, target}
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  defp resolve_tags(agent) do
    case GitAgent.tags(agent) do
      {:ok, tags} ->
        resolve_revisions(agent, tags)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_branches(agent) do
    with {:ok, branches} <- GitAgent.branches(agent),
         {:ok, branches} <- resolve_revisions(agent, branches) do
      case GitAgent.head(agent) do
        {:ok, head} ->
          {:ok, {head, branches}}
        {:error, _reason} ->
          {:ok, {nil, branches}}
      end
    end
  end

  defp resolve_revisions(agent, revs) do
    GitAgent.transaction(agent, fn agent ->
      Enum.reduce_while(Enum.reverse(revs), {:ok, []}, &resolve_revision(agent, &1, &2))
    end)
  end

  defp resolve_revision(agent, %GitRef{} = rev, {:ok, acc}) do
    with {:ok, commit} <- GitAgent.peel(agent, rev, target: :commit),
         {:ok, author} <- GitAgent.commit_author(agent, commit),
         {:ok, timestamp} <- GitAgent.commit_timestamp(agent, commit) do
      {:cont, {:ok, [{rev, author, timestamp}|acc]}}
    else
      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp resolve_revision(agent, %GitTag{} = tag, {:ok, acc}) do
    case GitAgent.tag_author(agent, tag) do
      {:ok, author} ->
        {:cont, {:ok, [{tag, author, author.timestamp}|acc]}}
      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp cleanup(_db, %{repo: repo}), do: RepoStorage.cleanup(repo)
end
