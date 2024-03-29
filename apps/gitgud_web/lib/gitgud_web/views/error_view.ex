defmodule GitGud.Web.ErrorView do
  @moduledoc """
  Module providing error views for most common errors.
  """

  use GitGud.Web, :view

  import GitGud.Web.LayoutView, only: [render_layout: 3]

  @spec template_not_found(binary, map) :: iodata
  def template_not_found(_template, assigns) do
    render("500.html", assigns)
  end

  @spec title(atom, map) :: binary
  def title(reason, _assigns) do
    reason
    |> Plug.Conn.Status.code()
    |> Plug.Conn.Status.reason_phrase()
  end
end
