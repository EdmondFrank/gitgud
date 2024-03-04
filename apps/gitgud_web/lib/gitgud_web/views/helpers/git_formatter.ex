defmodule GitGud.Web.GitFormatter do
  @moduledoc """
  Conveniences for formatting git objects.
  """

  @doc """
  Returns the string resprensent of the given OID.
  """
  @spec inspect_oid(<<_::160>>) :: String
  def inspect_oid(oid) do
    oid
    |> Base.encode16(case: :lower)
  end
end
