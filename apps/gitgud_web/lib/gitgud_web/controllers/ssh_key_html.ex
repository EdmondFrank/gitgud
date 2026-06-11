defmodule GitGud.Web.SSHKeyHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "ssh_key_html/*"

  @spec title(atom, map) :: binary
  def title(action, _assigns) when action in [:new, :create], do: "Settings · Add a new SSH key"
  def title(_action, _assigns), do: "Settings · SSH keys"
end
