defmodule GitGud.Web.FileFormatter do
  @moduledoc """
  Conveniences for translating and building file stat messages.
  """

  @doc """
  Truncate the given text
  """
  def truncate(text, opts \\ []) do
    max_length  = opts[:max_length] || 50
    omission    = opts[:omission] || "..."

    cond do
      not String.valid?(text) ->
        text
      String.length(text) < max_length ->
        text
      true ->
        length_with_omission = max_length - String.length(omission)
        "#{String.slice(text, 0, length_with_omission)}#{omission}"
    end
  end

  @doc """
  Format file size in human mode
  """
  def fmt_size(size, units \\ ["", "K", "M", "G", "T", "P", "E", "Z"], suffix \\ "B") do
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
