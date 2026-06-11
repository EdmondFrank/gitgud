defmodule GitGud.Web.SessionHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "session_html/*"

  @spec title(atom, map) :: binary
  def title(action, _assign) when action in [:new, :create], do: "Login"
end
