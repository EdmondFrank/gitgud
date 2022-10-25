defmodule GitGud.Web.FileFormatterTest do
  use ExUnit.Case, async: true

  import GitGud.Web.FileFormatter

  test "formats file size in human model" do
    assert fmt_size(1024) == "1.00KB"
    assert fmt_size(1024 * 1024) == "1.00MB"
    assert fmt_size(1024 * 1024 * 1024) == "1.00GB"
    assert fmt_size(1024 * 1024 * 1024 * 1024) == "1.00TB"

    assert fmt_size(123456) == "120.56KB"
    assert fmt_size(12345789) == "11.77MB"
  end
end
