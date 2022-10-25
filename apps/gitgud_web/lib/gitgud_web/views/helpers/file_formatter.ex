defmodule GitGud.Web.FileFormatter do
  @moduledoc """
  Conveniences for translating and building file stat messages.
  """

  @doc """
  Format file size in human mode
  """
  def fmt_size(size, units \\ ['', 'K', 'M', 'G', 'T', 'P', 'E', 'Z'], suffix \\ "B") do
    if is_integer(size) do
      do_fmt_size(size / 1, units, suffix)
    else
      case Integer.parse(size) do
        {num, _} -> fmt_size(num)
        :error -> "unknown size"
      end
    end
  end

  defp do_fmt_size(size, [unit | _], suffix) when abs(size) < 1024.0 do
    "#{to_string(:io_lib.format("~.2f", [size]))}#{unit}#{suffix}"
  end

  defp do_fmt_size(size, [_ | rest_units], suffix) do
    do_fmt_size(size / 1024, rest_units, suffix)
  end

  defp do_fmt_size(size, [], suffix) do
    "#{to_string(:io_lib.format("~.2f", [size]))}Y#{suffix}"
  end
end
