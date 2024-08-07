defmodule GitGud.Web.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  use Phoenix.HTML

  @doc """
  Generates tag for inlined form input errors.
  """
  def error_tag(form, field) do
    Enum.map(Keyword.get_values(form.errors, field), fn (error) ->
      content_tag :p, translate_error(error), class: "help is-danger"
    end)
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Because error messages were defined within Ecto, we must
    # call the Gettext module passing our Gettext backend. We
    # also use the "errors" domain as translations are placed
    # in the errors.po file.
    # Ecto will pass the :count keyword if the error message is
    # meant to be pluralized.
    # On your own code and templates, depending on whether you
    # need the message to be pluralized or not, this could be
    # written simply as:
    #
    #     dngettext "errors", "1 file", "%{count} files", count
    #     dgettext "errors", "is invalid"
    #
    if count = opts[:count] do
      Gettext.dngettext(GitGud.Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GitGud.Web.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Returns an error message for an upload error.

  See [`upload_errors/2`](`Phoenix.Component.upload_errors/2`).
  """
  def upload_error_to_string(:too_large), do: "The file is too large"
  def upload_error_to_string(:too_many_files), do: "You have selected too many files"
  def upload_error_to_string(:not_accepted), do: "You have selected an unacceptable file type"
  def upload_error_to_string(:external_client_failure), do: "Something went terribly wrong"
end
