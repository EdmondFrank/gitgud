defmodule GitGud.Web.TokenController do
  @moduledoc """
  Module responsible for CRUD actions on `GitGud.PersonalAccessToken`.

  The plaintext token is revealed exactly once, on the response to `create/2`
  (see `token_html/show.html.heex`); it is never written to a flash message, a
  session or a log. See `guides/MCP.md` §9.
  """

  use GitGud.Web, :controller

  alias GitGud.PersonalAccessToken
  alias GitGud.PersonalAccessTokenQuery

  plug :ensure_authenticated
  plug :put_layout, html: :user_settings

  action_fallback GitGud.Web.FallbackController

  @doc """
  Renders personal access tokens.
  """
  @spec index(Plug.Conn.t(), map) :: Plug.Conn.t()
  def index(conn, _params) do
    tokens =
      PersonalAccessTokenQuery.user_tokens(current_user(conn), order_by: [desc: :inserted_at])

    render(conn, "index.html", tokens: tokens)
  end

  @doc """
  Renders a creation form for personal access tokens.
  """
  @spec new(Plug.Conn.t(), map) :: Plug.Conn.t()
  def new(conn, _params) do
    changeset = PersonalAccessToken.changeset(%PersonalAccessToken{})
    render(conn, "new.html", changeset: changeset, scopes: PersonalAccessToken.scopes())
  end

  @doc """
  Creates a new personal access token and reveals its plaintext once.
  """
  @spec create(Plug.Conn.t(), map) :: Plug.Conn.t()
  def create(conn, %{"token" => token_params}) do
    case PersonalAccessToken.create(current_user(conn), normalize_params(token_params)) do
      {:ok, {token, plaintext}} ->
        render(conn, "show.html", token: token, plaintext: plaintext)

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Something went wrong! Please check error(s) below.")
        |> put_status(:bad_request)
        |> render("new.html",
          changeset: %{changeset | action: :insert},
          scopes: PersonalAccessToken.scopes()
        )
    end
  end

  @doc """
  Deletes a personal access token.
  """
  @spec delete(Plug.Conn.t(), map) :: Plug.Conn.t()
  def delete(conn, %{"token" => token_params}) do
    user = current_user(conn)
    token_id = String.to_integer(token_params["id"])

    case Enum.find(PersonalAccessTokenQuery.user_tokens(user), &(&1.id == token_id)) do
      nil ->
        {:error, :bad_request}

      token ->
        token = PersonalAccessToken.delete!(token)

        conn
        |> put_flash(:info, "Access token '#{token.name}' deleted.")
        |> redirect(to: ~p"/settings/tokens")
    end
  end

  #
  # Helpers
  #

  defp normalize_params(token_params) do
    token_params
    |> Map.put(
      "scopes",
      token_params |> Map.get("scopes", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    )
    |> put_expires_at()
  end

  defp put_expires_at(%{"expires_in_days" => days} = token_params) do
    case Integer.parse(to_string(days)) do
      {days, ""} when days > 0 ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(days * 86_400, :second)
          |> DateTime.truncate(:second)

        token_params
        |> Map.delete("expires_in_days")
        |> Map.put("expires_at", expires_at)

      _other ->
        Map.delete(token_params, "expires_in_days")
    end
  end

  defp put_expires_at(token_params), do: Map.delete(token_params, "expires_in_days")
end
