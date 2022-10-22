defmodule GitGud.Web.Gravatar do
  @moduledoc """
  Conveniences for rendering Gravatars.
  """

  alias GitGud.User
  alias GitGud.Uploaders.Avatar

  import Phoenix.HTML.Tag

  @doc """
  Renders a Gravatar widget for the given `email`.
  """
  @spec gravatar(User.t, keyword) :: binary
  def gravatar(user, opts \\ [])
  def gravatar(%User{avatar_url: nil}, _opts), do: []
  def gravatar(%User{avatar_url: url}, opts) do
    opts = Keyword.put_new(opts, :size, 28)
    {url_opts, opts} = Keyword.split(opts, [:size])
    {size, url_opts} = Keyword.get_and_update(url_opts, :size, &{&1, &1*2})
    url = URI.parse(url)
    url = struct(url, query: URI.encode_query(url_opts))
    img_class = if size < 28, do: "avatar is-small", else: "avatar"
    img_tag(to_string(url), Keyword.merge(opts, class: img_class, width: size))
  end

  @doc """
  Renders a custom avatar widget for the given `email`.
  """
  @spec user_avatar(User.t, keyword) :: binary
  def user_avatar(user, opts \\ [])
  def user_avatar(%User{avatar_url: nil}, _opts), do: []
  def user_avatar(%User{avatar_url: avatar_url} = user, opts) do
    opts = Keyword.put_new(opts, :size, 28)
    {url_opts, opts} = Keyword.split(opts, [:size])
    {size, _} = Keyword.get_and_update(url_opts, :size, &{&1, &1*2})
    img_class = if size < 28, do: "avatar is-small", else: "avatar"
    img_tag(Avatar.url({avatar_url, user}, signed: true), Keyword.merge(opts, class: img_class, width: size))
  end
end
