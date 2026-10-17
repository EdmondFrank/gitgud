defmodule GitGud.Web.Endpoint do
  @moduledoc """
  HTTP and WebSocket endpoints.
  """

  use Phoenix.Endpoint, otp_app: :gitgud_web
  use Absinthe.Phoenix.Endpoint

  @session_opts [
    store: :cookie,
    key: "_gitgud_web_key",
    signing_salt: "zMguVWdH",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_opts]],
    longpoll: false

  plug Plug.Static,
    at: "/uploads",
    from: "#{Application.compile_env(:waffle, :storage_dir_prefix)}/uploads",
    gzip: true

  plug Plug.Static,
    at: "/", from: :gitgud_web, gzip: false,
    only: ~w(assets css fonts images js),
    only_matching: ~w(favicon apple-touch-icon icon-192 icon-512 manifest robots)

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 200_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_opts

  plug GitGud.Web.Router
end
