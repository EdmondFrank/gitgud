defmodule GitGud.MetaDB do
  @moduledoc """
  MetaDB implements a metadata storage. It stores user credentials and Meta information
  """
  use GenServer
  @db_location Application.get_env(__MODULE__, :data_dir, "priv/meta-data")

  defmodule MetaObject do
    defstruct [:oid, :size, :existing]
  end

  @doc """
  Starts the metadata storage server as part of a supervision tree.
  """
  @spec start_link(keyword) :: GenServer.on_start
  def start_link(opts \\ []) do
    opts = Keyword.put(opts, :data_dir, @db_location)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def db do
    __MODULE__
    |> GenServer.call(:db)
    |> Map.get(:db)
  end

  def get(key) do
    case CubDB.get(db(), key) do
      nil -> nil
      meta ->
        obj = meta
        |> encode_and_decode()
        struct(MetaObject, obj)
    end
  end

  def list({min, max}) do
    db()
    |> CubDB.select(min_key: min, max_key: max)
  end

  def values(min, max) do
    db()
    |> CubDB.select(
      min_key: min,
      max_key: max,
      max_key_inclusive: false
    )
    |> Stream.map(fn {_, v} -> v end)
  end

  def put(key, value) do
    db()
    |> CubDB.put(key, value)
  end

  def file_path do
    @db_location
  end

  @doc false
  @impl true
  def init(opts) do
    {:ok, db} = CubDB.start_link(opts)
    {:ok, %{db: db}}
  end

  @doc false
  @impl true
  def handle_call(:db, _from, state) do
    {:reply, state, state}
  end

  defp encode_and_decode(object) do
    Jason.decode!(Jason.encode!(object), keys: :atoms)
  end
end
