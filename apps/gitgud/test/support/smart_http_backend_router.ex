defmodule GitGud.SmartHTTPBackendRouter do
  use Plug.Router

  alias GitGud.SmartHTTPBackend

  plug :match
  plug :fetch_query_params
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/:user_login/:repo_name/info/refs", to: SmartHTTPBackend, init_opts: :discover
  post "/:user_login/:repo_name/git-receive-pack", to: SmartHTTPBackend, init_opts: :receive_pack
  post "/:user_login/:repo_name/git-upload-pack", to: SmartHTTPBackend, init_opts: :upload_pack
  post "/:user_login/:repo_name/info/lfs/objects/batch", to: SmartHTTPBackend, init_opts: :batch
  get "/:user_login/:repo_name/info/lfs/objects", to: SmartHTTPBackend, init_opts: :download_object
  put "/:user_login/:repo_name/info/lfs/objects", to: SmartHTTPBackend, init_opts: :upload_object
end
