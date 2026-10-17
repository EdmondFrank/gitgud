defmodule GitGud.Web.ErrorHTMLTest do
  use GitGud.Web.ConnCase, async: true

  test "renders the 404 error page for an unknown route", %{conn: conn} do
    conn = get(conn, "/does-not/match/anywhere")
    body = html_response(conn, 404)

    assert body =~ "Not Found"
    assert body =~ "The page you were looking for could not be found."
    assert body =~ ~s(class="hero")
  end
end
