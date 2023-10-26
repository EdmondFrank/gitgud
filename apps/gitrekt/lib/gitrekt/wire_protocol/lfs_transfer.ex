defmodule GitRekt.WireProtocol.LfsTransfer do
  @moduledoc """
  Module implementing the `git-lfs-transfer` command.
  """

  @behaviour GitReket.WireProtocol

  alias GitRekt.GitAgent

  require Logger

  defstruct [:agent, state: :disco, version: 1, caps: []]

  @type t :: %__MODULE__{
    agent: GitAgent.agent,
    state: :disco | :vsn_seq |:done,
    version: integer(),
    caps: [binary()]
  }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush|lines]) do
    {%{handle|state: :done, caps: []}, lines, []}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    {%{handle|state: :vsn_seq, caps: []}, lines, Enum.concat([], [:flush])}
  end

  def next(%__MODULE__{state: :vsn_seq} = handle, [:flush|lines]) do
    {%{handle|state: :done, caps: []}, lines, []}
  end

  def next(%__MODULE__{state: :vsn_seq} = handle, ["version " <> _version|lines]) do
    {%{handle|state: :vsn_seq, caps: []}, lines, ["status ", "200", :flush]}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    {handle, [], []}
  end

  @impl true
  def skip(%__MODULE__{state: :disco} = handle), do: %{handle|state: :vsn_seq, caps: []}
  def skip(%__MODULE__{state: :vsn_seq} = handle), do: %{handle|state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle
end
