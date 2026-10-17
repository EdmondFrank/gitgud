defmodule GitGud.Web.MailerHTML do
  @moduledoc false
  use GitGud.Web, :html

  # The `_html`/`_text` suffixes keep the two formats of the same template
  # from clashing (both `verify_email.html.heex` and `verify_email.text.heex`
  # would otherwise compile to a `verify_email/1` function).
  embed_templates "mailer_html/*.html", suffix: "_html"
  embed_templates "mailer_html/*.text", suffix: "_text"

  # `Bamboo.Phoenix` renders emails through the legacy `Phoenix.View` API,
  # which requires the view module to export a `render/2` function that
  # returns iodata for the `"<template>.<format>"` template name.
  def render("verify_email.html", assigns), do: verify_email_html(assigns)
  def render("verify_email.text", assigns), do: render_text(verify_email_text(assigns))
  def render("reset_password.html", assigns), do: reset_password_html(assigns)
  def render("reset_password.text", assigns), do: render_text(reset_password_text(assigns))

  defp render_text(rendered),
    do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
end
