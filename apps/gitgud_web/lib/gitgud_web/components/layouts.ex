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

  # `Bamboo.Phoenix` renders the mailer layout through the legacy
  # `Phoenix.View` API, which requires a `render/2` function.
  def render("mailer.html", assigns), do: mailer(assigns)

  @doc """
  Renders the shared top navigation bar and the flash messages.

  Every page layout (`app`, `hero`, `repo`, `user_profile`, `user_settings`
  and `repo_settings`) renders this component so the application chrome is
  kept regardless of the layout selected with `put_layout/2`.
  """
  attr :conn, :any, default: nil
  attr :socket, :any, default: nil
  attr :current_user, :any, default: nil
  attr :flash, :map, default: %{}

  def page_header(assigns) do
    assigns = assign(assigns, :renderer, assigns.conn || assigns.socket)

    ~H"""
    <nav class="navbar is-spaced" aria-label="dropdown navigation">
      <div class="container">

        <div class="navbar-brand">
          <a class="navbar-item" href={~p"/"}>
            <img src={~p"/images/logo.svg"} alt="" width="48" height="48" />
          </a>
        </div>

        <div class="navbar-menu">
          <div class="navbar-start">
            <div class="navbar-item">
              <%= live_render(@renderer, GitGud.Web.GlobalSearchLive, id: "global-search", container: {:div, class: "global-search", data_phx_connect_later: true}) %>
            </div>
          </div>

          <div class="navbar-end">
            <%= if @current_user do %>
              <div class="navbar-item has-dropdown is-hoverable">
                <a class="navbar-link">
                  <%= user_avatar(@current_user, id: "viewer-avatar", size: 28) %>
                  <span id="viewer-login"><%= @current_user.login %></span>
                </a>
                <div class="navbar-dropdown is-right">
                  <a class="navbar-item" href={~p"/#{@current_user}"}>Profile</a>
                  <a class="navbar-item" href={~p"/settings/profile"}>Settings</a>
                  <hr class="navbar-divider">
                  <a class="navbar-item" href={~p"/logout"}>Logout</a>
                </div>
              </div>
            <% else %>
              <a class="navbar-item" href={~p"/register"}>Register</a>
              <a class="navbar-item" href={~p"/login"}>Login</a>
            <% end %>
          </div>
        </div>
      </div>
    </nav>

    <div id="flash">
      <%= if info = Phoenix.Flash.get(@flash, :info) do %>
        <article class="message is-primary is-small is-fixed">
          <div class="message-header">
            <p>Info</p>
            <button class="delete is-small" aria-label="delete"></button>
          </div>
          <div class="message-body"><%= info %></div>
        </article>
      <% end %>
      <%= if error = Phoenix.Flash.get(@flash, :error) do %>
        <article class="message is-danger is-small is-fixed">
          <div class="message-header">
            <p>Error</p>
            <button class="delete is-small" aria-label="delete"></button>
          </div>
          <div class="message-body"><%= error %></div>
        </article>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the repository breadcrumb and the Code/Issues/Settings tabs.

  Used by the `repo` and `repo_settings` layouts and works for both controller
  pages (through `conn`) and LiveViews (through `socket`).
  """
  attr :repo, :any, required: true
  attr :helper, :atom, default: nil
  attr :action, :atom, default: nil
  attr :current_user, :any, default: nil
  attr :open_issues, :any, default: nil
  attr :revision, :any, default: nil

  def repo_header(assigns) do
    ~H"""
    <nav class="breadcrumb is-large" aria-label="breadcrumbs">
      <span class="icon is-large"><i class="fa fa-box-open"></i></span>
      <ul>
        <li><h1 class="title"><a href={~p"/#{@repo.owner_login}"}><%= @repo.owner_login %></a></h1></li>
        <li>
          <h1 class="title">
            <a href={~p"/#{@repo.owner_login}/#{@repo.name}"}>
              <%= @repo.name %>
              <%= unless @repo.public do %>
                &nbsp;
                <span class="tag is-large has-text-grey-light"><i class="fa fa-lock"></i></span>
              <% end %>
            </a>
          </h1>
        </li>
      </ul>
    </nav>

    <% {helper, action} = {@helper, @action} %>
    <div class="tabs">
      <ul>
        <li class={if helper in [:codebase, :tree_browser_live, :commit_diff_live], do: "is-active"}>
          <%= if @revision do %>
            <a href={~p"/#{@repo.owner_login}/#{@repo.name}/tree/#{@revision}"}>
              <span class="icon"><i class="fa fa-code" aria-hidden="true"></i></span>
              <span>Code</span>
            </a>
          <% else %>
            <a href={~p"/#{@repo.owner_login}/#{@repo.name}"}>
              <span class="icon"><i class="fa fa-code" aria-hidden="true"></i></span>
              <span>Code</span>
            </a>
          <% end %>
        </li>
        <li class={if helper in [:issue, :issue_live, :issue_label], do: "is-active"}>
          <a href={~p"/#{@repo.owner_login}/#{@repo.name}/issues"}>
            <span class="icon"><i class="fa fa-exclamation-circle" aria-hidden="true"></i></span>
            <span>Issues</span>
            <%= if @open_issues do %>
              &nbsp;<span class="tag"><%= @open_issues %></span>
            <% end %>
          </a>
        </li>
        <li class={if helper == :checkpoint_live, do: "is-active"}>
          <a href={~p"/#{@repo.owner_login}/#{@repo.name}/sessions"}>
            <span class="icon"><i class="fa fa-robot" aria-hidden="true"></i></span>
            <span>Sessions</span>
          </a>
        </li>
        <%= if authorized?(@current_user, @repo, :admin) do %>
        <li class={if (helper == :repo && action in [:edit, :update]) || helper == :maintainer, do: "is-active"}>
          <a href={~p"/#{@repo.owner_login}/#{@repo.name}/settings"}>
            <span class="icon is-small"><i class="fa fa-cog" aria-hidden="true"></i></span>
            <span>Settings</span>
          </a>
        </li>
        <% end %>
      </ul>
    </div>
    """
  end

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
