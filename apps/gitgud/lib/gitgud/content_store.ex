defmodule GitGud.ContentStore do
  use GenServer

  @content_location Application.get_env(__MODULE__, :data_dir, "priv/lfs-data")

  def start_link(opts \\ []) do
    opts = Keyword.put(opts, :data_dir, @content_location)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    base_path = opts[:data_dir]
    :ok = File.mkdir_p(base_path)
    {:ok, base_path}
  end

  def get_path(meta) do
    GenServer.call(__MODULE__, {:get, meta})
  end

  def get(meta, from_byte) do
    GenServer.call(__MODULE__, {:get, meta, from_byte})
  end

  def put(meta, content) do
    GenServer.call(__MODULE__, {:put, meta, content})
  end

  def exists?(meta) do
    GenServer.call(__MODULE__, {:exists?, meta})
  end

  defp transform_key(key) do
    if String.length(key) < 5 do
      key
    else
      Path.join([String.slice(key, 0..1), String.slice(key, 2..3), String.slice(key, 4..-1)])
    end
  end

  def handle_call({:exists?, meta}, _from, base_path) do
    path = Path.join(base_path, transform_key(meta.oid))

    case File.exists?(path) do
      true -> {:reply, true, base_path}
      false -> {:reply, false, base_path}
    end
  end

  def handle_call({:get, meta}, _from, base_path) do
    path = Path.join(base_path, transform_key(meta.oid))

    with {:ok, _stat} <- File.stat(path) do
      {:reply, {:ok, path}, base_path}
    else
      {:error, error} -> {:reply, {:error, error}, base_path}
    end
  end

  def handle_call({:get, meta, from_byte}, _from, base_path) do
    path = Path.join(base_path, transform_key(meta.oid))
    with {:ok, file} <- :file.open(path, [:read, :binary]),
         :ok <- move_file_position(file, from_byte) do
      {:reply, {:ok, file}, base_path}
    else
      {:error, error} -> {:reply, {:error, error}, base_path}
    end
  end

  def handle_call({:put, meta, content}, _from, base_path) do
    path = Path.join(base_path, transform_key(meta.oid))
    tmp_path = "#{path}.tmp"
    dir = Path.dirname(path)

    with :ok <- create_directory(dir),
         :ok <- write_content(tmp_path, content),
           :ok <- validate_file_size(tmp_path, meta.size),
           :ok <- validate_file_hash(tmp_path, meta.oid),
           :ok <- rename_file(tmp_path, path)
      do
      {:reply, :ok, base_path}
      else
        {:error, reason} ->
          # File.rm(tmp_path)
        {:reply, {:error, reason}, base_path}
    end
  end

  defp move_file_position(_file, 0), do: :ok
  defp move_file_position(file, pos) do
    case :file.position(file, pos) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp create_directory(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_content(file, content) do
    case File.write(file, content) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_size(file, meta_size) do
    case File.stat(file) do
      {:ok, %{size: size}} ->
        if size == meta_size, do: :ok, else: {:error, :size_not_match}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_hash(file, meta_hash) do
    initial_hash_state = :crypto.hash_init(:sha256)
    hash =
      File.stream!(file, [], 2048)
      |> Enum.reduce(initial_hash_state, &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    if hash == meta_hash, do: :ok, else: {:error, :hash_not_match}
  end

  defp rename_file(tmp_path, path) do
    case File.rename(tmp_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
