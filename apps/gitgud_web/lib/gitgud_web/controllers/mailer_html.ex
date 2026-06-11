defmodule GitGud.Web.MailerHTML do
  @moduledoc false
  use GitGud.Web, :html

  embed_templates "mailer_html/*"
end
