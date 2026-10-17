defmodule GitGud.MCP.LazyPlug do
  @moduledoc """
  A lazy wrapper around `Anubis.Server.Transport.StreamableHTTP.Plug`.

  `Plug.Router.forward/2` (and Phoenix's `forward/4`) call `init/1` at compile
  time, but the Anubis plug resolves its runtime configuration from
  `:persistent_term`, which is only populated once the server supervisor starts
  at runtime. This plug therefore keeps `init/1` inert and defers the Anubis
  `init/1` + `call/2` to request time.

  Mounted at `/api/mcp` from `GitGud.Web.Router`.

  Adapted from `Exhub.MCP.LazyPlug` (see `~/Code/exhub`).
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    plug_opts = Anubis.Server.Transport.StreamableHTTP.Plug.init(opts)
    Anubis.Server.Transport.StreamableHTTP.Plug.call(conn, plug_opts)
  end
end
