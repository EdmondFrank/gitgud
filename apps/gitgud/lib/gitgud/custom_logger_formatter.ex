defmodule GitGud.CustomLoggerFormatter do
  @moduledoc """
  Custom logger formatter for Erlang reports.
  """

  def handle_event({_level, _gl, _pid, {:ssl, :ssl_alert, {type, desc, data}}}, _config) do
    try do
      :ssl_alert.own_alert_format(type, desc, data, [])
    catch
      :undef, _ ->
        "TLS ALRT: #{inspect(type)} #{inspect(desc)} #{inspect(data)}\n"
    end
  end

  def handle_event({_level, _gl, _pid, {:ssl, :ssl_error, {reason, data}}}, _config) do
    "TLS ERR: #{inspect(reason)} #{inspect(data)}\n"
  end

  def handle_event(log_event, config) do
    :logger_formatter.format(log_event, config)
  end
end
