defmodule GitGud.Web.AuthenticationPlug do
  @moduledoc """
  `Plug` providing support for multiple authentication methods.
  """

  @behaviour Plug

  import Plug.Conn

  alias GitGud.Authorization
  alias GitGud.PersonalAccessToken
  alias GitGud.PersonalAccessTokenQuery
  alias GitGud.User
  alias GitGud.UserQuery

  @doc """
  `Plug` to authenticate `conn` with either authorization or session tokens.
  """
  @spec authenticate(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def authenticate(conn, opts) do
    conn = authenticate_bearer_token(conn, opts)

    unless authenticated?(conn),
      do: authenticate_session(conn, opts),
      else: conn
  end

  @doc """
  `Plug` to authenticate `conn` with session tokens.
  """
  @spec authenticate_session(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def authenticate_session(conn, _opts) do
    if user_id = get_session(conn, :user_id),
      do: authenticate_user(conn, user_id),
      else: conn
  end

  @doc """
  `Plug` to authenticate `conn` with authorization tokens.
  """
  @spec authenticate_bearer_token(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def authenticate_bearer_token(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- Phoenix.Token.verify(endpoint(conn), "bearer", token, max_age: 86400) do
      authenticate_user(conn, user_id)
    else
      _ ->
        conn
    end
  end

  @doc """
  `Plug` to authenticate `conn` with a personal access token.

  The token is read from either the `Authorization: Bearer gf_…` or the
  `X-Api-Key: gf_…` header. On success the resolved token is assigned to
  `conn.assigns.personal_access_token` (used by the MCP scope gate, see
  `guides/MCP.md` §9) and the owning user to `conn.assigns.current_user`.

  This is deliberately **not** part of `authenticate/2`, so a personal access
  token can only be used where it is explicitly wired in (the MCP endpoint).
  """
  @spec authenticate_personal_access_token(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def authenticate_personal_access_token(conn, _opts) do
    with token when is_binary(token) <- personal_access_token(conn),
         {:ok, pat} <- PersonalAccessTokenQuery.authenticate(token) do
      _ = maybe_touch(pat)

      conn
      |> assign(:personal_access_token, pat)
      |> authenticate_user(pat.user_id)
    else
      _other ->
        conn
    end
  end

  @doc """
  `Plug` to ensure that the request is authenticated.

  If the given `conn` is not `authenticated?/1`, this prevents further plugs downstream from being
  invoked and returns a *401 Unauthenticated* error.
  """
  @spec ensure_authenticated(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def ensure_authenticated(conn, _opts) do
    unless authenticated?(conn) do
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.put_layout(false)
      |> Phoenix.Controller.put_view(GitGud.Web.ErrorView)
      |> Phoenix.Controller.render(:"401")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Returns `true` if the given `conn` is authenticated; otherwise returns `false`.
  """
  @spec authenticated?(Plug.Conn.t()) :: boolean
  def authenticated?(conn), do: !!current_user(conn)

  @doc """
  Returns `true` if the given `conn` is allowed to perform `action` on `resource`; otherwhise returns `false`.
  """
  @spec authorized?(Plug.Conn.t(), any, atom) :: boolean
  def authorized?(%Plug.Conn{} = conn, resource, action),
    do: authorized?(current_user(conn), resource, action)

  defdelegate authorized?(user, resource, action), to: Authorization

  @doc """
  Returns `true` if the given `conn` is authenticated with a verified user; otherwise returns `false`.
  """
  @spec verified?(Plug.Conn.t()) :: boolean
  def verified?(%Plug.Conn{} = conn), do: verified?(current_user(conn))
  defdelegate verified?(user), to: User

  @doc """
  Returns the current user if `conn` is authenticated.
  """
  @spec current_user(Plug.Conn.t()) :: GitGud.User.t() | nil
  def current_user(conn), do: conn.assigns[:current_user]

  @doc """
  Generates an authentication token.
  """
  @spec authentication_token(Plug.Conn.t()) :: binary | nil
  def authentication_token(%Plug.Conn{} = conn) do
    if authenticated?(conn),
      do: Phoenix.Token.sign(endpoint(conn), "bearer", current_user(conn).id),
      else: nil
  end

  #
  # Callbacks
  #

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts), do: authenticate(conn, opts)

  #
  # Helpers
  #

  defp endpoint(conn) do
    if Map.has_key?(conn.private, :phoenix_endpoint),
      do: conn,
      else: GitGud.Web.Endpoint
  end

  defp authenticate_user(conn, user_id) do
    if user = UserQuery.by_id(user_id) do
      conn
      |> assign(:current_user, user)
      |> assign(:avatar_changeset, GitGud.Account.change_user_avatar(user))
    else
      conn
    end
  end

  # Records `last_used_at` only when it is missing or stale, so an authenticated
  # request does not trigger a database write every time.
  @touch_interval 60

  defp maybe_touch(%PersonalAccessToken{} = pat) do
    if is_nil(pat.last_used_at) or
         DateTime.diff(DateTime.utc_now(), pat.last_used_at) > @touch_interval do
      PersonalAccessTokenQuery.touch(pat)
    end
  end

  defp personal_access_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        personal_access_token_candidate(token)

      _other ->
        conn
        |> get_req_header("x-api-key")
        |> List.first()
        |> personal_access_token_candidate()
    end
  end

  defp personal_access_token_candidate(token) when is_binary(token) do
    if String.starts_with?(token, PersonalAccessToken.token_prefix()), do: token
  end

  defp personal_access_token_candidate(_token), do: nil
end
