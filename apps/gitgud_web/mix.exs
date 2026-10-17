defmodule GitGud.Web.Mixfile do
  use Mix.Project

  def project do
    [
      app: :gitgud_web,
      version: "0.3.9",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GitGud.Web.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  #
  # Helpers
  #

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:absinthe, "~> 1.7"},
      {:absinthe_relay, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:anubis_mcp, "~> 1.14"},
      {:bamboo, "~> 2.2"},
      {:bamboo_smtp, "~> 4.2"},
      {:bamboo_phoenix, "~> 1.0"},
      {:earmark, "~> 1.4"},
      {:cmark, "~> 0.10.0"},
      # Same pin as the umbrella root, but it has to be repeated here: the check that
      # fails is the one Mix runs in *this* app's context (`mix assets.deploy` in the
      # Dockerfile), and that run never loads the root `mix.exs`. See
      # `apps/gitgud/mix.exs` / `mix.exs` — no version changes, just `override: true`.
      {:ecto, "~> 3.9", override: true},
      {:floki, "~> 0.33", only: :test},
      {:gettext, "~> 0.20"},
      {:gitgud, in_umbrella: true},
      {:oauth2, "~> 2.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_view, "~> 2.0"},
      {:phoenix_live_reload, "~> 1.3", only: :dev},
      {:phoenix_live_view, "~> 0.19"},
      {:phoenix_pubsub, "~> 2.1"},
      {:waffle, "~> 1.1"},
      {:waffle_ecto, "~> 0.0"},
      {:plug, "~> 1.13"},
      {:plug_cowboy, "~> 2.5"},
      {:telemetry, "~> 1.1"},
      {:timex, "~> 3.7"}
    ]
  end

  defp aliases do
    [
      "assets.deploy": ["cmd --cd assets node build.js --deploy", "phx.digest"],
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end
end
