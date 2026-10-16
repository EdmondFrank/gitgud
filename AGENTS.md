# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## 1. Project overview

**gitgud** (published as *gitfrank* / *git.limo*) is a self-hosted Git source-code
management service written in Elixir. It provides:

- A web UI (Phoenix + LiveView, GitHub-like).
- A full **GraphQL API** (Absinthe + Relay).
- Git transport over **SSH** and **Smart HTTP** (`git clone/push/fetch`).
- Issue tracker, code reviews, releases, OAuth2 login, email, SSH/GPG keys, LFS.

The umbrella is split into three applications (see `guides/Getting Started.md`):
`:gitrekt`, `:gitgud`, `:gitgud_web`.

## 2. Architecture / where things live

| App | Path | Responsibility |
| --- | --- | --- |
| `:gitrekt` | `apps/gitrekt` | Low-level Git bindings to **libgit2** via a C **NIF** (`geef_nif.so`, `c_src/*.c`) plus native Git transfer protocols (upload-pack/receive-pack) and PACK format. Compiled with `elixir_make` + `Makefile`. |
| `:gitgud` | `apps/gitgud` | Domain layer: Ecto schemas (`GitGud.User`, `GitGud.Repo`, …), query modules (`*Query`), DB repos (`GitGud.DB` = Postgres; `GitGud.MetaDB` = CubDB key-value store), `GitGud.ContentStore` (LFS objects), authorization, repository pool/storage/supervisor, `GitGud.SSHServer`, `GitGud.SmartHTTPBackend` (Plug). |
| `:gitgud_web` | `apps/gitgud_web` | Phoenix 1.7 web app: `Endpoint`, `Router`, controllers, views (legacy `.eex`) and **LiveView**, components, plugs, **GraphQL schema** (`lib/gitgud/graphql`), file uploaders (Waffle), mailer (Bamboo). |

Key entry points:
- Supervision tree: `apps/gitgud/lib/gitgud/application.ex` (starts DB, MetaDB, ContentStore, RepoSupervisor, SSHServer).
- Routes: `apps/gitgud_web/lib/gitgud_web/router.ex`.
- DB repos & migrations: `apps/gitgud/lib/gitgud/db.ex`, `apps/gitgud/priv/db/migrations/`.
- Release migration task: `apps/gitgud/lib/gitgud/release_tasks.ex` (used by container entrypoint).

## 3. Prerequisites

- **ASDF** with the versions in `.tool-versions`: `elixir 1.17.3-otp-27`, `erlang 27.1.2`.
- **libgit2** installed (`brew install libgit2` on macOS; `libgit2-dev` on Debian/Ubuntu). `gitrekt` compiles a C NIF that links against it.
- **Node.js** (for the asset pipeline; `asdf` provides it).
- **Docker** with Compose (for the PostgreSQL database).
- `libcluster` is used for distribution; a single node works for local dev.

## 4. Local setup (quickstart)

```bash
# 1. Toolchain (Elixir/Erlang from .tool-versions)
asdf install

# 2. Database — always the Docker image, never a system Postgres
docker compose -f docker-compose-dev.yml up -d

# 3. Elixir deps + compile
mix deps.get
MIX_ENV=dev mix compile

# 4. Database schema + seed data
MIX_ENV=dev mix ecto.setup      # ecto.create + ecto.migrate + priv/db/seeds.exs

# 5. JS assets (only needed once; already present in node_modules)
npm install --prefix apps/gitgud_web/assets

# 6. Run
MIX_ENV=dev mix phx.server      # HTTP on :4000, SSH git server on :9989
```

Open <http://localhost:4000>. Clone over SSH with `ssh://git@localhost:9989/<user>/<repo>`.

> `docker-compose-dev.yml` starts `postgres:16-alpine` (container `postgres_dev`,
> volume `postgres_data`) with db `gitfrank_dev`, user `gitfrank_user`,
> password `gitfrank_pass`, on port `5432`. These exact values are in
> `apps/gitgud/config/dev.exs` — keep them in sync.
>
> The other file, `docker-compose.yml`, is the **production release image**
> (`ccr.ccs.tencentyun.com/edmondfrank/gitfrank`). Do **not** use it for local development.

SSH host keys must exist in `apps/gitgud/priv/ssh-keys/` (generate with
`ssh-keygen -m PEM -t rsa -f apps/gitgud/priv/ssh-keys/ssh_host_rsa_key`).

## 5. ⚠️ MIX_ENV — read this first

The shell environment in which agents run here exports **`MIX_ENV=prod`**. A bare
`mix` command therefore loads prod config, and `config/runtime.exs` will abort with
e.g. `** (RuntimeError) environment variable SECRET_KEY_BASE is missing`.

**Always prefix environment-specific commands:**

```bash
MIX_ENV=dev  mix phx.server
MIX_ENV=dev  mix ecto.setup
MIX_ENV=test mix test
```

(`mix test` forces `:test`, but pass `MIX_ENV=test` explicitly to be safe.)

## 6. Common commands

| Task | Command |
| --- | --- |
| Start dev server (HTTP :4000, SSH :9989) | `MIX_ENV=dev mix phx.server` |
| Create/migrate/seed DB | `MIX_ENV=dev mix ecto.setup` |
| Drop + recreate DB | `MIX_ENV=dev mix ecto.reset` |
| New migration | `MIX_ENV=dev mix ecto.gen.migration <name>` (lands in `apps/gitgud/priv/db/migrations/`) |
| Run tests | `MIX_ENV=test mix test` |
| Run one test file | `MIX_ENV=test mix test apps/gitgud/test/gitgud/repo_test.exs` |
| Format | `mix format` (Elixir defaults — see §8) |
| Build production assets | `mix assets.deploy` (= `node build.js --deploy` + `phx.digest`) |
| Start/stop DB | `docker compose -f docker-compose-dev.yml up -d` / `down` |

Asset pipeline: `apps/gitgud_web/assets/build.js` uses **esbuild** + `esbuild-sass-plugin`
(entry `js/index.js`, output `../priv/static/assets`). In dev the endpoint runs the
watcher automatically (`node build.js --watch`).

## 7. Testing

- Runner: ExUnit. Root alias `test:` in `mix.exs` runs `ecto.create --quiet`,
  `ecto.migrate`, then `test`.
- **Test database config** lives in `apps/gitgud/config/test.exs`: it uses the same
  Docker credentials as dev (`gitfrank_user` / `gitfrank_pass`) and database
  `gitgud_test`. When `GITHUB_ACTIONS` is set (CI) it overrides to `postgres/postgres`.
- Tests use **`Ecto.Adapters.SQL.Sandbox`** in `:manual` mode. `GitGud.DataCase` and
  `GitGud.Web.ConnCase` check out a connection and share it for non-async tests.
  A test that touches the DB cannot be `async: true` unless it manages its own sandbox.
- Test support modules live in `apps/*/test/support/` (compiled only for `:test`;
  see `elixirc_paths(:test)` in each `mix.exs`).
- **Known pre-existing failures:** ~25 web tests currently fail because legacy
  `.eex` templates call `Routes.*` (i.e. `GitGud.Web.Router.Helpers`, no longer
  generated). The project is mid-migration to `Phoenix.VerifiedRoutes`
  (`GitGud.Web.verified_routes/0`). These failures are **not** environment-related —
  don't "fix" them by changing DB config; they need the templates/helpers updated.

## 8. Conventions & style

- Elixir 1.17 / OTP 27. Umbrella where each child app sets
  `build_path: "../../_build"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`.
- Namespacing: `GitRekt.*`, `GitGud.*` (domain), `GitGud.Web.*` (web).
- **No root `.formatter.exs`** exists, so `mix format` uses Elixir defaults. If you add
  one, wire it through the umbrella inputs so child apps share it.
- Config is layered: `config/config.exs` wildcard-imports every `apps/*/config/config.exs`,
  then imports the env-specific file. Production values come from `config/runtime.exs`
  env vars (`SECRET_KEY_BASE`, `DATABASE_URL`, `GIT_ROOT`, `SSH_HOST_KEY_DIR`,
  `UPLOADS_DIR`, …). See `.env.example` (production only — dev needs no `.env`).
- GraphQL uses **Absinthe + Relay**. Convert IDs with `from_relay_id/1` / `to_relay_id/2`
  from `GitGud.GraphQL.Schema`. The SDL (`priv/graphql/schema.graphql`) is regenerated by
  `GitGud.GraphQL.SchemaGenerator` when the schema module checksum changes.
- Migrations are plain Ecto migrations; some use raw SQL (Postgres extensions, triggers,
  `ENUM` types) — test them against the Postgres container.
- Prefer existing helpers over new ones: `GitGud.Web.PaginationHelpers`, `GitGud.Web.NavigationHelpers`,
  `GitGud.Web.Markdown`, `GitGud.Web.DateTimeFormatter`, etc.

## 9. Gotchas

- **`MIX_ENV=prod` in the shell** — see §5. This is the #1 source of confusing failures.
- **libgit2 / NIF compilation** — `:gitrekt` compiles `c_src/*.c` into `priv/geef_nif.so`
  during `mix compile`. If compilation or git ops fail, verify libgit2 is installed
  (`brew --prefix libgit2`) and that `make`/a C compiler is available.
- **MetaDB & ContentStore need `:data_dir`** — `GitGud.MetaDB.start_link/1` and
  `GitGud.ContentStore.start_link/1` `Keyword.fetch!` their `:data_dir`. Both dev and
  test configs set it (test writes under `apps/gitgud/test/data/`).
- **Ports**: dev HTTP `4000`, SSH git `9989`; test SSH `9899`; production SSH `1022`/HTTP `4000`.
- **Uploads**: `Plug.Parsers` allows up to 200 MB; static served from `/uploads` and app statics.
- **Two DB "repos"**: `GitGud.DB` (Postgres/Ecto) is not the same as `GitGud.MetaDB`
  (CubDB file store). Git objects live on disk under `GitGud.RepoStorage` (`git_root`).
- **Generated/ignored artifacts**: `apps/*/log/`, `apps/*/priv/meta-data/`, root `priv/`,
  `_build/`, `deps/` are git-ignored or untracked; `erl_crash.dump` may appear in the root.

## 10. CI & contributing

- CI: `.github/workflows/elixir.yml` — Ubuntu, `postgres:11` service, `libgit2-dev`,
  generates SSH keys, `mix deps.get`, then `mix test`.
- `CONTRIBUTING.md`: write tests, follow the Elixir community style guide, use good
  commit messages. Run `MIX_ENV=test mix test` before opening a PR.