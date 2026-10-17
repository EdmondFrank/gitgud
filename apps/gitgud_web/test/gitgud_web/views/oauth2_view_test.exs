defmodule GitGud.Web.OAuth2ViewTest do
  use ExUnit.Case, async: true

  alias GitGud.Web.OAuth2View

  test "signin_button links to the provider authorize route" do
    html = OAuth2View.signin_button(%Plug.Conn{}, "github") |> Phoenix.HTML.safe_to_string()
    assert html =~ ~s(href="/auth/github")
  end
end