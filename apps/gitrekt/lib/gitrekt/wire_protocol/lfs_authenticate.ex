defmodule GitRekt.WireProtocol.LfsAuthenticate do
  @moduledoc """
  Module implementing the `git-lfs-authenticate` command.
  """

  @behaviour GitReket.WireProtocol

  alias GitRekt.GitAgent

  alias GitGud.Web.Endpoint

  require Logger

  defstruct [
    agent: nil,
    state: :disco,
    caps: [],
    user_login: nil,
    repo_name: nil
  ]

  @type t :: %__MODULE__{
    agent: GitAgent.agent,
    state: :disco | :done,
    caps: [binary()],
    user_login: binary() | nil,
    repo_name: binary() | nil
  }


  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush|lines]) do
    {%{handle|state: :done, caps: []}, lines, []}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    token = Phoenix.Token.sign(Endpoint, "bearer", handle.user_login)

    result = %{
      href: "#{Endpoint.url()}/#{handle.user_login}/#{handle.repo_name}.git/info/lfs",
      header: %{
        authorization: "Bearer #{token}"
      },
      expires_at: Timex.now |> Timex.shift(hours: 24) |> DateTime.to_iso8601
    }

    {%{handle|state: :done, caps: []}, lines, Jason.encode!(result)}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    {handle, [], []}
  end

  @impl true
  def skip(%__MODULE__{state: :disco} = handle), do: %{handle|state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle
end
