defmodule GitGud.Web.IssueLabelViewTest do
  use ExUnit.Case, async: true

  alias GitGud.IssueLabel
  alias GitGud.Repo
  alias GitGud.Web.IssueLabelView

  test "label_button links to the issue search for the given repository" do
    conn = %Plug.Conn{assigns: %{repo: %Repo{owner_login: "kanle", name: "gitfrank"}}}
    label = %IssueLabel{name: "bug", color: "ffffff"}

    html = IssueLabelView.label_button(conn, label, []) |> Phoenix.HTML.safe_to_string()
    assert html =~ ~s(href="/kanle/gitfrank/issues?q=)
    assert html =~ "bug"
  end
end
