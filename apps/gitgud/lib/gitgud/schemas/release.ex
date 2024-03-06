defmodule GitGud.Release do
  @moduledoc """
  Release schema and helper functions
  """
  use Ecto.Schema

  alias GitGud.DB
  alias GitGud.Repo
  alias GitGud.User
  alias GitGud.Attachment

  import Ecto.Changeset

  schema "releases" do
    field :title, :string
    field :description, :string
    field :release_type, :string
    field :tag_version, :string
    field :revision, :string
    belongs_to :repo, Repo
    belongs_to :author, User
    has_many :attachments, Attachment, foreign_key: :attachable_id, where: [attachable_type: "release"]
    timestamps()
  end

  @type t :: %__MODULE__{
    id: pos_integer,
    title: binary,
    description: binary,
    release_type: binary,
    tag_version: binary,
    revision: binary,
    repo: Repo.t,
    repo_id: pos_integer,
    author: User.t,
    author_id: pos_integer,
    inserted_at: NaiveDateTime.t,
    updated_at: NaiveDateTime.t
  }

  @doc """
  Creates a new release with the given attributes.

  ```elixir
  {:ok, release} = GitGud.Release.create(
    repo,
    author,
    title: "Test Release v1.0.0",
    description: "First release",
    release_type: "normal",
    tag_version: "v1.0.0",
    revision: "b4304988d8bfdb4d17d78778ae2c7904b3778012",
  )
  ```
  """
  @spec create(Repo.t, User.t, map | keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def create(repo, author, params) do
    %__MODULE__{repo_id: repo.id, author_id: author.id}
    |> changeset(params)
    |> DB.insert()
  end

  @doc """
  Similar to `create/3`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(Repo.t, User.t, map | keyword) :: t
  def create!(repo, author, params) do
    %__MODULE__{repo_id: repo.id, author_id: author.id}
    |> changeset(params)
    |> DB.insert!()
  end

  @spec update(t, map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def update(%__MODULE__{} = release, params) do
    release
    |> changeset(params)
    |> DB.update()
  end

  @doc """
  Similar to `update/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec update!(t, map|keyword) :: t
  def update!(%__MODULE__{} = release, params) do
    release
    |> changeset(params)
    |> DB.update!()
  end

  @doc """
  Deletes the given `release`.

  ```elixir
  {:ok, release} = GitGud.Release.delete(release)
  ```
  """
  @spec delete(t) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def delete(%__MODULE__{} = release) do
    DB.delete(release)
  end

  @doc """
  Similar to `delete!/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec delete!(t) :: t
  def delete!(%__MODULE__{} = release) do
    DB.delete!(release)
  end

  @doc """
  Return a changeset for the given `params`
  """
  @spec changeset(t, map) :: Ecto.Changeset.t
  def changeset(%__MODULE__{} = release, params \\ %{}) do
    release
    |> cast(params, [:title, :description, :release_type, :tag_version, :revision])
    |> validate_required([:title, :description, :tag_version, :revision])
  end
end
