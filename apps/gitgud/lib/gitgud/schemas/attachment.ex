defmodule GitGud.Attachment do

  @moduledoc """
  Attachment schema and helper functions.

  An attachment is a file uploaded by a user.
  """
  use Ecto.Schema

  use Waffle.Ecto.Schema

  import Ecto.Changeset

  alias GitGud.DB
  alias GitGud.Release


  schema "attachments" do
    field :key, :string
    field :filename, :string
    field :byte_size, :integer
    field :service_name, :string, default: "local"
    field :metadata, :map
    field :checksum, :string
    field :content_type, :string
    field :attachable_id, :integer
    field :attachable_type, :string
    timestamps()
  end

  @type t :: %__MODULE__{
    id: pos_integer,
    key: binary,
    filename: binary,
    byte_size: pos_integer,
    service_name: binary,
    metadata: map,
    checksum: binary,
    content_type: binary,
    attachable_id: pos_integer,
    attachable_type: binary,
    inserted_at: NaiveDateTime.t,
    updated_at: NaiveDateTime.t
  }

  @doc """
  Return a changeset for the given `params`.
  """
  @spec changeset(map) :: Ecto.Changeset.t
  def changeset(%__MODULE__{} = attachment, params \\ %{}) do
    attachment
    |> cast(params, [:key, :filename, :byte_size, :service_name, :metadata, :checksum, :content_type, :attachable_id, :attachable_type])
    |> validate_required([:key, :filename, :byte_size, :attachable_id, :attachable_type])
  end

  @doc """
  Creates a new attament with the given attributes.

  ```elixir
  {:ok, attachment} = GitGud.Attachment.create(
    key: "76b6a8f0e7b863fb3a780bd18d489b21c419f9a8be253c2272d4d086e0ee4e98",
    filename: "13914416.png",
    byte_size: 302836,
    attachable_id: 5,
    attachable_type: "release",
    service_name: "local",
    metadata: %{},
    checksum: "76b6a8f0e7b863fb3a780bd18d489b21c419f9a8be253c2272d4d086e0ee4e98"
  )
  ```
  """
  @spec create(Release.t, map | keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def create(release = %Release{}, params) do
    %__MODULE__{attachable_id: release.id, attachable_type: "release"}
    |> changeset(params)
    |> DB.insert()
  end

  @doc """
  Similar to `create/3`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(Release.t, map | keyword) :: t
  def create!(release = %Release{}, params) do
    %__MODULE__{attachable_id: release.id, attachable_type: "release"}
    |> changeset(params)
    |> DB.insert!()
  end
end
