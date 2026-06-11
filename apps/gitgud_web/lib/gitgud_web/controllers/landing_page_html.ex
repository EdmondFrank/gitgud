defmodule GitGud.Web.LandingPageHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "landing_page_html/*"

  @spec title(atom, map) :: binary
  def title(:index, _assigns), do: "Code collaboration for dev teams"
end
