defmodule GitGud.FileLoggerBackend do
  @moduledoc """
  A pure Elixir file logger backend that supports rotation.
  """
  require Logger

  defstruct path: nil,
            level: nil,
            format: nil,
            metadata: nil,
            device: nil,
            size: 10_485_760, # 10MB
            files: 5

  #
  # Logger.Backend callbacks
  #

  def init({__MODULE__, name}) do
    config = Application.get_env(:logger, name, [])

    config =
      config
      |> Keyword.put_new(:level, :debug)
      |> Keyword.put_new(:format, "$time $metadata[$level] $message\n")
      |> Keyword.put_new(:metadata, [])
      |> Keyword.put_new(:size, 10_485_760)
      |> Keyword.put_new(:files, 5)

    path = Keyword.fetch!(config, :path)

    # Ensure directory exists
    :ok = File.mkdir_p(Path.dirname(path))

    case File.open(path, [:write, :append, :delayed_write, :utf8]) do
      {:ok, device} ->
        state = %__MODULE__{
          path: path,
          level: config[:level],
          format: config[:format],
          metadata: config[:metadata],
          device: device,
          size: config[:size],
          files: config[:files]
        }

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    if Logger.compare_levels(level, state.level) != :lt and not Keyword.get(md, :backend_error, false) do
      state = maybe_rotate(state)
      message = if is_function(msg, 0), do: msg.(), else: msg
      log_entry = format_log(state.format, level, message, ts, md, state.metadata)
      IO.write(state.device, log_entry)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  def handle_event(:flush, state) do
    :ok = :file.sync(state.device)
    {:ok, state}
  end

  def handle_call({:configure, _opts}, state) do
    # For simplicity, this backend does not support dynamic reconfiguration.
    # To reconfigure, remove and re-add the backend.
    {:ok, :ok, state}
  end

  def terminate(_reason, state) do
    if state.device, do: :file.close(state.device)
  end

  #
  # Helpers
  #

  defp maybe_rotate(state) do
    case File.stat(state.path) do
      {:ok, %{size: current_size}} ->
        if current_size > state.size do
          rotate(state)
        else
          state
        end

      {:error, :enoent} ->
        # File might have been deleted. Re-open it.
        case File.open(state.path, [:write, :append, :delayed_write, :utf8]) do
          {:ok, device} ->
            %{state | device: device}
          {:error, reason} ->
            Logger.error(
              "FileLoggerBackend failed to open #{inspect(state.path)}: #{inspect(reason)}",
              backend_error: true
            )

            state
        end

      {:error, reason} ->
        # Other error, log and continue.
        Logger.error(
          "FileLoggerBackend failed to stat #{inspect(state.path)}: #{inspect(reason)}",
          backend_error: true
        )

        state
    end
  end

  defp rotate(state) do
    :file.close(state.device)
    path = state.path
    files = state.files

    # Delete oldest log file if it exists
    File.rm(path <> ".#{files}")

    # Rotate existing log files
    for i <- (files - 1)..1//-1 do
      from = path <> ".#{i}"
      to = path <> ".#{i+1}"

      if File.exists?(from) do
        File.rename(from, to)
      end
    end

    # Rename current log file
    if File.exists?(path) do
      File.rename(path, path <> ".1")
    end

    # Open new log file
    case File.open(path, [:write, :append, :delayed_write, :utf8]) do
      {:ok, device} ->
        %{state | device: device}

      {:error, reason} ->
        Logger.error(
          "FileLoggerBackend failed to open new log file #{inspect(path)} after rotation: #{inspect(reason)}",
          backend_error: true
        )

        # Try to recover by setting device to nil. It will be reopened on next log.
        %{state | device: nil}
    end
  end

  defp format_log(format, level, msg, ts, md, metadata_keys) do
    time_str = to_string(format_time(ts))
    metadata_str = format_metadata(md, metadata_keys)
    message = to_string(msg)

    format
    |> String.replace("$time", time_str)
    |> String.replace("$metadata", metadata_str)
    |> String.replace("$level", to_string(level))
    |> String.replace("$message", message)
  end

  defp format_metadata(all, keys) do
    case Keyword.take(all, keys) do
      [] ->
        ""

      taken ->
        data =
          Enum.map_join(taken, " ", fn {k, v} ->
            "#{k}=#{v}"
          end)

        "[#{data}]"
    end
  end

  defp format_time({_date, {h, m, s}}) do
    :io_lib.format("~2.10.0B:~2.10.0B:~2.10.0B", [h, m, s])
  end

  defp format_time({_date, {h, m, s, ms}}) do
    :io_lib.format("~2.10.0B:~2.10.0B:~2.10.0B.~3.10.0B", [h, m, s, ms])
  end
end
