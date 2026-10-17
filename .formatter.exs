# Umbrella-wide formatter configuration.
#
# The umbrella root has the single `mix.lock`/`deps`/`_build`, so a root
# `.formatter.exs` that globs every child app keeps `mix format` consistent
# across `:gitrekt`, `:gitgud` and `:gitgud_web`.
#
# `Phoenix.LiveView.HTMLFormatter` is what makes `mix format` format `.heex`
# (and `.leex`) templates instead of choking on them.
[
  import_deps: [:ecto, :ecto_sql, :phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "apps/*/{mix,.formatter}.exs",
    "apps/*/config/*.{ex,exs}",
    "apps/*/{lib,test}/**/*.{ex,exs,heex,leex}"
  ]
]