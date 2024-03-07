defmodule GitGud.Uploaders.Attachment do
  use Waffle.Definition

  # Include ecto support (requires package waffle_ecto installed):
  use Waffle.Ecto.Definition#

  @versions [:original]

  # Whitelist file extensions:
  # def validate({file, _}) do
  #   file_extension = file.file_name |> Path.extname() |> String.downcase()

  #   case Enum.member?(~w(.jpg .jpeg .gif .png), file_extension) do
  #     true -> :ok
  #     false -> {:error, "invalid file type"}
  #   end
  # end

  # Override the persisted filenames:
  def filename(_version, {file, _scope}) do
    sha256(file.path)
  end

  def sha256(path) do
    File.stream!(path, [], 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn line, acc -> :crypto.hash_update(acc,line) end)
    |> :crypto.hash_final
    |> Base.encode16(case: :lower)
  end

  # Override the storage storage_dir_prefix:
  def storage_dir_prefix() do
    Application.get_env(:waffle, :priv_storage_dir_prefix)
  end

  # Override the storage directory:
  def storage_dir(_version, {_file, scope}) do
    "uploads/release/#{scope.id}"
  end

end
