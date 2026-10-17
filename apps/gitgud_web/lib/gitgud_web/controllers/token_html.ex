defmodule GitGud.Web.TokenHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "token_html/*"

  @spec title(atom, map) :: binary
  def title(action, _assigns) when action in [:new], do: "Settings · Add a new access token"
  def title(action, _assigns) when action in [:create], do: "Settings · Access token created"
  def title(_action, _assigns), do: "Settings · Access tokens"
end
