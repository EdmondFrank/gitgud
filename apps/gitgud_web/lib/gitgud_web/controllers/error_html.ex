defmodule GitGud.Web.ErrorHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "error_html/*"

  @spec template_not_found(binary, map) :: iodata
  def template_not_found(template, assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @spec title(atom, map) :: binary
  def title(reason, _assigns) do
    reason
    |> Plug.Conn.Status.code()
    |> Plug.Conn.Status.reason_phrase()
  end
end
