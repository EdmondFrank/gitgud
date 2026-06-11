defmodule GitGud.Web.Layouts do
  @moduledoc """
  This module holds different layouts used in the application.

  By default, Phoenix 1.7 uses root and app layouts.
  """
  use GitGud.Web, :html

  import Phoenix.Controller, only: [get_flash: 2, action_name: 1, view_module: 1, get_csrf_token: 0]
  import Phoenix.HTML.Tag

  import GitGud.Web.AuthenticationPlug, only: [
    authenticated?: 1,
    authentication_token: 1,
    authorized?: 3,
    current_user: 1,
    verified?: 1
  ]

  import GitGud.Web.NavigationHelpers
  import GitGud.Web.Gravatar

  # Root layout - the HTML shell
  embed_templates "layouts/*"

  @spec session_params(Plug.Conn.t) :: keyword
  def session_params(conn) do
    cond do
      current_route?(conn, :landing_page) -> []
      current_route?(conn, :session) -> []
      current_route?(conn, :user, :new) -> []
      true -> [redirect_to: conn.request_path]
    end
  end

  @spec title(Plug.Conn.t, binary) :: binary
  def title(conn, default \\ ""), do: conn.assigns[:page_title] || view_title(conn) || default

  #
  # Helpers
  #

  defp view_title(conn) do
    try do
      case view_module(conn) do
        GitGud.Web.ErrorView = view ->
          apply(view, :title, [Plug.Conn.Status.reason_atom(conn.status), conn.assigns])
        view ->
          apply(view, :title, [action_name(conn), conn.assigns])
      end
    rescue
      _error ->
        nil
    end
  end
end
