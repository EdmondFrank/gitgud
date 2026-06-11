defmodule GitGud.Web.ReleaseHTML do
  @moduledoc false
  use GitGud.Web, :html

  import GitGud.Web.PaginationHelpers, only: [paginate: 2, paginate: 3, paginate_cursor: 4, paginate_cursor: 5, pagination: 2]

  embed_templates "release_html/*"
end
