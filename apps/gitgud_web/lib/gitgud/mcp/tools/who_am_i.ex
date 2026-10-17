defmodule GitGud.MCP.Tools.WhoAmI do
  @moduledoc """
  MCP tool `whoami` — returns the user authenticated for the current request.

  The user is resolved by `GitGud.MCP.AuthPlug` and reaches the tool through the
  Anubis frame (`frame.assigns[:current_user]`). See `guides/MCP.md` §10.
  """

  alias Anubis.Server.Response

  use Anubis.Server.Component, type: :tool

  def name, do: "whoami"

  @impl true
  def description do
    """
    Return the gitfrank user authenticated for the current MCP session.

    Use this to confirm which account a token or session belongs to before
    performing further actions. Returns the user's numeric id, login and display
    name.
    """
  end

  schema do
    # No parameters required.
  end

  @impl true
  def execute(_params, frame) do
    response =
      case frame.assigns[:current_user] do
        %GitGud.User{} = user ->
          Response.json(Response.tool(), %{"ok" => true, "data" => user_data(user)})

        _other ->
          Response.json(Response.tool(), %{"ok" => false, "error" => "unauthenticated"})
      end

    {:reply, response, frame}
  end

  #
  # Helpers
  #

  defp user_data(user) do
    %{"id" => user.id, "login" => user.login, "name" => user.name}
  end
end
