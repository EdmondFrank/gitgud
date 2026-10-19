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
| `:gitrekt` | `apps/gitrekt` | Low-level Git bindings to **libgit2** via a **NIF** (`geef_nif.so`, `c_src/*.c`) plus native Git transfer protocols (upload-pack/receive-pack) and PACK format. Built by `elixir_make` + `Makefile`, which drives `zig build` (`build.zig`) — both locally and in the production image. |
| `:gitgud` | `apps/gitgud` | Domain layer: Ecto schemas (`GitGud.User`, `GitGud.Repo`, …), query modules (`*Query`), DB repos (`GitGud.DB` = Postgres; `GitGud.MetaDB` = CubDB key-value store), `GitGud.ContentStore` (LFS objects), authorization, repository pool/storage/supervisor, `GitGud.SSHServer`, `GitGud.SmartHTTPBackend` (Plug). |
| `:gitgud_web` | `apps/gitgud_web` | Phoenix 1.7 web app: `Endpoint`, `Router`, controllers, views (legacy `.eex`) and **LiveView**, components, plugs, **GraphQL schema** (`lib/gitgud/graphql`), file uploaders (Waffle), mailer (Bamboo). |

Key entry points:
- Supervision tree: `apps/gitgud/lib/gitgud/application.ex` (starts DB, MetaDB, ContentStore, RepoSupervisor, SSHServer).
- AI-native MCP server (Streamable HTTP, `POST /api/mcp`): `apps/gitgud_web/lib/gitgud/mcp/` —
  see `guides/MCP.md`. Started from `GitGud.Web.Application`; tools live under `GitGud.MCP.Tools.*`.
- Routes: `apps/gitgud_web/lib/gitgud_web/router.ex`.
- DB repos & migrations: `apps/gitgud/lib/gitgud/db.ex`, `apps/gitgud/priv/db/migrations/`.
- Release migration task: `apps/gitgud/lib/gitgud/release_tasks.ex` (used by container entrypoint).

## 3. Prerequisites

- **ASDF** with the versions in `.tool-versions`: `elixir 1.18.2-otp-27`, `erlang 27.1.2`,
  `zig 0.17.0`. (Elixir ≥ 1.18 is required by `anubis_mcp`, the MCP server framework — see
  `guides/MCP.md`.)
- **libgit2** installed (`brew install libgit2` on macOS; `libgit2-dev` on Debian/Ubuntu). `gitrekt` compiles a NIF that links against it.
- **Zig 0.17** builds that NIF (`apps/gitrekt/build.zig`). It replaced the raw `$(CC)`
  invocation because GCC 14 and clang 20+ promote several C diagnostics — notably
  `-Wincompatible-pointer-types` — from warnings to **errors**, which broke the build on
  modern toolchains. `asdf install` provides it locally; the production image installs
  the same version from either the official tarball or the `ziglang` PyPI wheel — both
  sha256-pinned and both statically linked, so they run on musl (Alpine only packages
  zig ≤ 0.16). `pkgconf` must be installed too — `zig build` resolves `libgit2` through
  `libgit2.pc`; see §4 for choosing the faster source on a CN build host.
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
> (`ccr.ccs.tencentyun.com/edmondfrank/gitfrank`); `docker compose -f docker-compose.yml build`
> builds and tags it. Do **not** use it for local development.
>
> That image builds entirely behind mirrors — apk (tuna), hex (upyun), npm (npmmirror)
> and either the Zig tarball or the `ziglang` PyPI wheel — all declared as `ARG`s at the
> top of the `Dockerfile`, so `--build-arg APK_MIRROR_HOST=… NPM_REGISTRY=… ZIG_MIRROR=…`
> switches to upstream endpoints. On a CN build host prefer
> `--build-arg ZIG_PIP_INDEX=https://mirrors.cloud.tencent.com/pypi/simple`: ziglang.org
> is Cloudflare-throttled to ~40 KB/s there, whereas the mirror returns the 101 MB wheel
> (same static `zig` + `lib/`) in seconds. A host-local proxy also works, with no
> Dockerfile change, via the predefined `HTTPS_PROXY` build arg. `.dockerignore` keeps
> `_build/`, `deps/`, `node_modules/`, the Zig cache and `.env` out of the build context.

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
| Format | `mix format` (root `.formatter.exs` — see §8) |
| Build production assets | `mix assets.deploy` (= `node build.js --deploy` + `phx.digest`) |
| Start/stop DB | `docker compose -f docker-compose-dev.yml up -d` / `down` |
| Build the production image | `docker compose -f docker-compose.yml build` |

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
- The `:gitgud_web` suite is currently **green** (`156 tests, 0 failures, 4 skipped`).
  Route generation is available from both worlds: the legacy `Routes.*` helpers
  (`GitGud.Web.Router.Helpers`, still generated in Phoenix 1.7) and
  `Phoenix.VerifiedRoutes` (`~p`/`url/1`). Controllers/live views get verified routes
  via `use GitGud.Web, :controller`/`:html`, legacy views via `use GitGud.Web, :view`,
  and tests via `GitGud.Web.ConnCase` (`use GitGud.Web, :verified_routes`).

## 8. Conventions & style

- Elixir 1.18 / OTP 27. Umbrella where each child app sets
  `build_path: "../../_build"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`.
- Namespacing: `GitRekt.*`, `GitGud.*` (domain), `GitGud.Web.*` (web).
- A root **`.formatter.exs`** globs every child app (`apps/*/{lib,test}`) and enables
  `Phoenix.LiveView.HTMLFormatter`, so `mix format` also formats `.heex`/`.leex`.
  It was added after the codebase was written, so the first `mix format` produces a
  large diff — format only the files you touch instead of the whole tree.
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
  during `mix compile`. The `Makefile` delegates to `zig build` (`apps/gitrekt/build.zig`)
  when a `zig` is on `PATH`, and otherwise falls back to the system `$(CC)`; both paths work.
  If compilation or git ops fail, verify libgit2 is installed (`brew --prefix libgit2`),
  that `zig version` reports 0.17.0 in the repo, and that `pkg-config --modversion libgit2`
  resolves. `ZIG_TARGET=<triple>` (e.g. `x86_64-linux-musl`) forces an explicit
  `-Dtarget`; the default is native. Cross-compiling the NIF for another target
  additionally needs that target's `libgit2` and `zlib` headers/libraries — Zig does not
  bundle them. The container takes the same path (Zig in `/opt/zig`, symlinked to
  `/usr/local/bin/zig`); note that Alpine 3.21 there ships **libgit2 1.8.4**, whose
  `git_odb_writepack` does expose the `free` callback `c_src/odb.c` relies on. Both
  Zig sources install the identical `zig` + `lib/` layout under `/opt/zig` (the wheel is
  simply unpacked there), so `zig build` behaves the same either way.
- **MetaDB & ContentStore need `:data_dir`** — `GitGud.MetaDB.start_link/1` and
  `GitGud.ContentStore.start_link/1` `Keyword.fetch!` their `:data_dir`. Both dev and
  test configs set it (test writes under `apps/gitgud/test/data/`).
- **Ports**: dev HTTP `4000`, SSH git `9989`; test SSH `9899`; production SSH `1022`/HTTP `4000`.
- **The SSH git server must report the exit status on the path where *it* ends the
  session.** `GitGud.SSHServer` (`apps/gitgud/lib/gitgud/ssh_server.ex`) has to call
  `:ssh_connection.exit_status/3` when upload-pack halts, not only when the client sends
  EOF: on a clone/fetch the client closes the channel as soon as it has the pack, so
  otherwise OpenSSH hands git `255` and it fails with `fatal: remote transport reported
  error` — for *every* repository. Report it exactly once (the `exit_status_sent` flag) or a
  push logs `mux_client_request_session: exitval sent twice` and git prints a spurious
  `error: failed to push some refs`. Covered by `ssh_server_test.exs` ("clones and fetches
  over SSH"). Details: `guides/Sessions and Checkpoints.md` §12.
- **`mix` in a child app ignores the umbrella root `mix.exs`** — a root-only
  `override: true` does not suppress a conflict seen from *inside* an app, which is exactly
  what `RUN cd apps/gitgud_web && mix assets.deploy` does. `peri` (pulled in by
  `anubis_mcp`) requires `ecto ~> 3.12` while the project pins 3.9, so the
  `{:ecto, "~> 3.9", override: true}` pin is repeated in `apps/gitgud/mix.exs` **and**
  `apps/gitgud_web/mix.exs`. Repro without any build:
  `cd apps/gitgud_web && MIX_ENV=prod mix deps.loadpaths` → `Unchecked dependencies …`.
  Symptom in a build: step `mix assets.deploy` dies with `** (Mix) Can't continue due to
  errors on dependencies`.
- **`docker-compose.yml` must stay free of `${VAR:-default}`** — the deploy host ships
  compose **v1**, which rejects every default-value form (`${VAR:-x}` and `${VAR-x}`) and
  then refuses to parse the whole file; only a bare `${VAR}` works.
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

## 11. AI-native MCP server (`POST /api/mcp`)

gitfrank exposes its domain over the **Model Context Protocol** (Streamable HTTP)
so AI agents can drive it. Design + phased plan: `guides/MCP.md`; client setup
(config snippets for AiderDesk / Claude Code / Zed / curl): `guides/MCP Clients.md`.

- **Endpoint** — `POST /api/mcp`; the `:mcp` pipeline is `fetch_session` →
  `GitGud.MCP.AuthPlug` (`apps/gitgud_web/lib/gitgud_web/router.ex`). Client
  setup: `guides/MCP Clients.md`.
- **Code** — `apps/gitgud_web/lib/gitgud/mcp/`: `server.ex` (tool registry),
  `server_helpers.ex` (tool filtering + scope gate + telemetry), `auth_plug.ex`,
  `authorization.ex` (resource **and** scope gates), `telemetry.ex`, and
  `tools/*.ex` (one module per tool). Domain support lives in `:gitgud`
  (`GitGud.PersonalAccessToken`, `PersonalAccessTokenQuery`).
- **Auth** — `Authorization: Bearer <Phoenix.Token>` (24h), `Authorization: Bearer
  gf_…` (personal access token) or `X-Api-Key: gf_…`, or the `:user_id` session
  cookie. Unauthenticated requests get a JSON-RPC 401 (`-32001`).
- **Scopes** — a PAT carries scopes (`user:read`, `repo:read`, `repo:write`,
  `issue:read`, `issue:write`, `review:write`); `tools/list` is filtered by scope
  and `tools/call` returns `insufficient_scope` when one is missing. Session/bearer
  credentials are unrestricted. The resource gate (`GitGud.Authorization`) always
  runs *in addition*.
- **Settings UI** — `/settings/tokens` (`GitGud.Web.TokenController` +
  `TokenHTML`) mints PATs; the plaintext is rendered once on create and never
  logged.
- **Config** — `:gitgud_web, :mcp` (`enabled`, `path`, `server_name`,
  `server_version`, `request_timeout`, `session_idle_timeout`, `telemetry`).
- **Telemetry** — `[:gitgud, :mcp, :tool, :call, :start | :stop]`; `:stop`
  metadata is `%{tool:, result: :ok | :error | :denied, user_id:, scopes:,
  session_id:, remote_ip:}`, logged by `GitGud.MCP.Telemetry.LoggerHandler`.
- **Tests** — `apps/gitgud_web/test/gitgud/mcp/` (`server_test.exs`,
  `tools_test.exs`, `write_tools_test.exs`, `personal_access_token_auth_test.exs`,
  `telemetry_test.exs`), `apps/gitgud_web/test/gitgud_web/controllers/token_controller_test.exs`,
  and `apps/gitgud/test/gitgud/personal_access_token_test.exs`.

## 12. AI coding-agent sessions (Entire checkpoints)

Design + phased plan: `guides/Sessions and Checkpoints.md`. **Phases 0–6 are done**; no
retention pruner was built and the optional control plane stays deferred.

Phase 1 is the domain ingest layer, `GitGud.Checkpoints`
(`apps/gitgud/lib/gitgud/checkpoints.ex`): `list/2`, `get/2`, `session/4`, `tasks/2`,
`prompts/2`, `commit_ids/2`, `for_commit/2`, `invalidate/1`. It reads the checkpoint trees out of the
repository's own object store via `GitGud.RepoPool`, and caches only the per-checkpoint
summaries in `GitGud.MetaDB` under `{:checkpoints, owner_login, name}`, guarded by a
reference-name/target-oid watermark (`MetaDB.get_raw/1` + `delete/1` were added for this;
`get/1` coerces its value into a `MetaObject`, so it cannot hold an arbitrary document).
`GitGud.Repo`'s `GitRekt.GitRepo.push/2` impl drops that cache when a push touches
`refs/entire/`. Config: `config :gitgud, GitGud.Checkpoints, enabled:, legacy_branch:,
max_transcript_bytes:`. Tests: `apps/gitgud/test/gitgud/checkpoints_test.exs`.

Phase 2 is the UI, `GitGud.Web.CheckpointLive`
(`apps/gitgud_web/lib/gitgud_web/live/checkpoint_live.ex` + `.html.heex`): the repository
**Sessions** tab — `live "/sessions"` (`:sessions`: the list, newest first, with `?p=`
pagination) and `live "/sessions/:id"` (`:session`: prompt, a 100-line transcript window
via `?page=`, files touched, the subagent task table, and a compact diff against
`metadata["commit_sha"]`). The route actions are `:sessions`/`:session` rather than
`:index`/`:show` because `CodebaseView.title/2`'s first clause already guards on
`action == :show`. `CommitHistoryLive` renders a chip per linked checkpoint from a single
`Checkpoints.list/2` call in `mount/3`; `CommitDiffLive` uses `Checkpoints.commit_ids/2`;
`repo_header/1` gained the tab. Tests:
`apps/gitgud_web/test/gitgud_web/live/checkpoint_live_test.exs` (mounting `CommitDiffLive`
under `Phoenix.LiveViewTest` raises *inside the harness* — `floki 0.33.1` dropped
`Floki.get_by_id/2`, which `phoenix_live_view 0.20.12` still calls). The fixture lives in
`apps/gitgud_web/test/support/checkpoint_factory.ex`, shared with Phase 3.

Phase 3 is the APIs. GraphQL (`apps/gitgud_web/lib/gitgud/graphql/{types,resolvers}.ex`):
`object :checkpoint` (+ `enum :checkpoint_source`, and a `scalar :json` — absinthe 1.7's
`Absinthe.Type.Custom` has none), a `checkpoints` connection and `checkpoint(id:)` on
`object :repo`, and a `checkpoints` connection on `object :git_commit` fed by
`Checkpoints.for_commit/2`. Its `oid`/`commit_sha` are `String` on purpose: the domain
yields 40-character hex while the `git_oid` scalar serializes with `Git.oid_fmt/1`, which
wants the raw 20-byte form (and `oid_parse`'s `raise`-only stub makes Elixir 1.18 warn at
any call site). There is no Relay `node`/`to_relay_id/2` — ids are ULIDs, and
`Schema.from_relay_id/1` coerces with `String.to_integer/1`. The SDL regenerates on compile
and is gitignored. MCP adds `list_checkpoints`, `get_checkpoint` (bounded: a transcript
only for an explicitly requested `session`, capped by `max_bytes`) and
`search_checkpoints` (prompt-only by default, capped at 100 checkpoints) — all
`repo:read`, so `@tool_scopes` in `GitGud.MCP.Authorization` grew by three and the tool
count in `apps/gitgud_web/test/gitgud/mcp/` is now **25** (26 after Phase 4). Tests:
`apps/gitgud_web/test/gitgud/graphql/checkpoint_test.exs` (real documents through
`Schema.run/2`, so `RepoMiddleware` is exercised — note `Schema.run/2` returns **atom**
keys for `:data`/`:errors`, while nested field maps are string-keyed) and
`apps/gitgud_web/test/gitgud/mcp/checkpoint_tools_test.exs`.

Phase 4 is search & provenance, all of it answered from the `GitGud.MetaDB` index — no Git
read, no transcript scan unless a caller explicitly asks. `Checkpoints.search/3` tokenises a
query the way the index is built (lowercased `[a-z0-9]+` runs, stop words and one-character
terms dropped, ≤16 terms per query), requires **every** term to hit a summary field (`id`,
`branch`, `strategy`, `commit_sha`, `files_touched`) or an indexed session prompt, and returns
`%{checkpoint:, matched: [label], score:}` — labels `"id"`/`"branch"`/`"strategy"`/
`"commit_sha"`/`"files_touched"`/`"session <n> prompt"`, weights 3 for a prompt or touched
file and 1 otherwise. The index document therefore grew a third key,
`%{watermark, checkpoints, terms}`, where `terms` is `term => [{checkpoint id, session index}]`
built from `<i>/prompt.txt` at the same time as the summaries; transcripts are never indexed.
`Checkpoints.provenance/3` maps a path (exact, or a `path <> "/"` prefix for a directory)
back to the checkpoints that touched it from `files_touched` alone. Surfaces: a `?q=` search
form and per-row match labels on the Sessions tab (pagination carries `q`, and a public repo
now renders the risk-1 exposure warning), the `search_checkpoints(query:)` /
`checkpoint_provenance(path:)` connections plus `object :checkpoint_match` on GraphQL
`object :repo`, and the MCP tools — `checkpoint_provenance` (the 26th, `repo:read`) and
`search_checkpoints`, rewritten onto `search/3` (`include_transcripts: true` still does the
bounded, opt-in scan of the 10 newest checkpoints). Risk 2 is closed: with `enabled: false`
the checkpoint refs are now omitted from advertisement —
`WireProtocol.reference_discovery/4` takes `hide_references:`, threaded as a `hide_references`
field on `UploadPack`/`ReceivePack` and set from `Checkpoints.hidden_reference_prefixes/0` in
both `GitGud.SSHServer` and `GitGud.SmartHTTPBackend`, so `:gitrekt` stays generic. Tests:
`apps/gitgud/test/gitgud/checkpoints_test.exs` (search/provenance) and
`apps/gitgud/test/gitgud/checkpoints_transport_test.exs` (the gate).

Phase 5 is hardening. 5A deletion tolerance needed no code — the reference-name/target-oid
watermark from Phase 1 already rebuilds when `entire clean` deletes a ref, and
`GitRekt.GitRepo.push/2` drops the cache eagerly — so it is tests (`describe "retention"`) and
docs. 5B added `Checkpoints.storage/1`, which walks every checkpoint tree summing **deduplicated**
blob sizes under two caps (`@max_storage_checkpoints`, `@max_storage_objects`; a hit cap makes the
number a documented lower bound, reported as `truncated?`), rendered as an **admin-only**
*Checkpoint storage* panel (`format_bytes/1`) on the Sessions tab. 5C is a push-side guard:
`:gitrekt` gained a generic `WireProtocol.valid_reference_name?/1` and a `reference_policy`
callback on `ReceivePack` (mirroring the `hide_references` threading), called for every reference
a push *writes* — deletes always pass — and emitting `ng <ref> <reason>` in place of `ok <ref>`;
`:gitgud` supplies `Checkpoints.reference_policy/0`, which refuses the whole `refs/entire/*`
namespace while `enabled: false` and any malformed name under it otherwise, at both transport call
sites. 5D makes every read accept an unambiguous case-insensitive id **prefix**
(≥ `@min_id_prefix_length` = 4) via `resolve_location/2`, returning `{:error, :ambiguous}` on a
multiple match (the GraphQL resolver and the MCP `get_checkpoint` each map that to their own
error). No retention pruner was built (the user declined one) and the control plane (§8 level B)
stays deferred. Tests: the `retention` / `short id resolution` / `storage/1` blocks in
`apps/gitgud/test/gitgud/checkpoints_test.exs`, `reference_policy/0` + `the push guard` in
`checkpoints_transport_test.exs`, `valid_reference_name?/1` in `git_reference_test.exs`, and the
storage-panel tests in `apps/gitgud_web/test/gitgud_web/live/checkpoint_live_test.exs`.

Phase 6 is the transcript viewer. It fixed two things a real capture exposed: `session/4`
preferred the agent-native `0/full.jsonl`, which for OpenCode is a *pretty-printed JSON document*
rather than JSON Lines, and the view assumed each line was `{"type":…,"text":…}` when the CLI's
normalised `0/transcript.jsonl` lines actually carry `content:` as a **list of parts** (a compact
*user* part has no `type` at all). So `session/4` gained a `:source` option (`:full`, the default,
or `:compact`, each falling back to the other, with the file read returned as `:source`) and the
detail view asks for `:compact`. `GitGud.Web.CheckpointTranscript`
(`apps/gitgud_web/lib/gitgud_web/checkpoint_transcript.ex`) normalises a line into
`%{role:, at:, text:, tools:, thinking:, tokens:, raw:}` — recognising the compact envelope, the
Claude Code `message.content` line and the OpenCode-native `info`/`parts` line, and passing
anything else through as `:raw` — and `checkpoint_live.html.heex` renders message cards (role tag,
timestamps, token counts, markdown text, tool calls in `<details>`, a `?tools=0` toggle) styled by
a new `assets/css/components/checkpoint/_all.scss`. `CheckpointFactory` now writes both transcripts
the way the CLI does and exposes `full_transcript/0` / `compact_transcript/0` / `prompt/0` /
`reply/0` / `tool/0` / `transcript_lines/0`. Tests: the new
`apps/gitgud_web/test/gitgud_web/checkpoint_transcript_test.exs` and the message/toggle cases in
`apps/gitgud_web/test/gitgud_web/live/checkpoint_live_test.exs` — `:gitgud` 220 tests, `:gitgud_web`
209, both green.

A live `entire` 0.11.5 run against a real capture then found two defects (guide §13), both fixed.
**A delete-only push hung.** `git send-pack` sends *no* packfile when every command in a push is a
deletion (`need_pack_data = 0`) and `ReceivePack` waited in `:pack` for one, so `:done` and
`report-status` never happened: `entire checkpoint delete` and plain `git push origin :branch` hung
for *every* user. `ReceivePack.next/2` now short-circuits to `:done` when the parsed commands are
all deletions *and* nothing is left to read — git's own `delete_only()` — and a client that sends a
pack anyway still has it consumed. Covered by `describe "a delete-only push"` in
`checkpoints_transport_test.exs`, and verified live (`- [deleted] <branch>` in ~0.1 s).
**And `commit_sha` was always `nil` for a real checkpoint**: CLI 0.11.5 writes no `commit_sha` into
`metadata.json` and the checkpoint commit is a *root* commit, so the only link is the
`Entire-Checkpoint:` trailer in the user's own commit. `GitGud.Checkpoints` now resolves it by
walking the branch each checkpoint records (`branch`, else `repo.default_branch`) newest-first and
bounded (`@max_link_commits`), caching `id => sha` in `GitGud.MetaDB` under
`{:checkpoints_links, owner_login, name, branch}` — keyed by the *branch tip oid*, so the push that
delivers the trailer invalidates it while a push of a checkpoint reference does not. `list/2`,
`get/2` and `for_commit/2` carry it, `CheckpointLive` diffs against the summary's `commit_sha`, and
`CheckpointFactory` no longer invents one, so the web tests exercise the resolution. Finally,
`String.slice(repo_name, 0..-5)` in `SSHServer.parse_args/1` became `String.trim_trailing/2` (and
two sibling negative-end ranges the explicit `//1` form), clearing the Elixir 1.18 negative-step
deprecation. `:gitgud` 225 tests, `:gitgud_web` 209, both green.

Phase 7 made the viewer handle **AiderDesk** captures, which write no compact transcript:
`0/full.jsonl` is a pretty-printed JSON *document* (`{"version":2,"contextMessages":[…]}`) whose
assistant entries carry `reasoning`/`text`/`tool-call` parts and whose tool *results* arrive as
separate `role:"tool"` entries, with epoch-millisecond `timestamp` and a per-message `usageReport`.
`GitGud.Web.CheckpointTranscript.transcript/1` (new; `messages/1` now delegates to it) joins the
lines and decodes a whole-document transcript — `contextMessages`, `messages`, a bare message or a
list of them — keeping the per-line path otherwise; a document *fragment* in which no line is
itself a JSON object (say one truncated past `:max_bytes`) renders as a **single** `:raw` block
instead of one card per line. It recognises the AiderDesk parts, reads epoch-ms stamps and
`usageReport` (`sentTokens`/`receivedTokens`/`model`/`messageCost`) alongside the compact envelope,
and folds each tool result into the call it answers (`toolCallId`, or Claude Code's `tool_use_id`)
so a call renders once with its input *and* output — the message map gained `call_id`/`model`/
`cost`. `CheckpointLive` now paginates **messages**, not raw lines (a document is only decodable as
a whole), the message header shows model/cost, an empty `"model": ""` counts as absent, and a
`:full` read is labelled *full agent transcript* rather than *raw*. `CheckpointFactory.write!/2`
takes `transcript: :aiderdesk`; verified against the real capture (740 lines → 15 messages, 0 raw).
`:gitgud` 225 tests, `:gitgud_web` 213, both green. Details: `guides/Sessions and Checkpoints.md`
§6 Phase 7.

The [Entire CLI](https://github.com/entireio/cli) captures AI coding-agent
sessions as **checkpoints** and pushes them to a git remote as ordinary refs —
`refs/entire/checkpoints/<shard>/<id>`, each pointing at a commit whose tree root
holds `metadata.json`, per-session `0/`, `1/`… directories (transcripts, prompts,
token usage) and `tasks/`. The commit that condensed the work carries an
`Entire-Checkpoint: <id>` trailer. There is no server API in that path: plain
`git push`/`git fetch` *is* the transport, so gitfrank can host checkpoints with
no control-plane work (the id-fronted HTTP API is only needed for `entire login`,
`org`/`project`/`repo` and `entire://` clones — see §8 of the guide).

Phase 0 made gitfrank safe for those refs:

- Reference names outside `refs/heads/` and `refs/tags/` are now classified
  `:other` — `GitRekt.GitAgent.resolve_reference_type/1`, the `GitRekt.GitRef`
  type — and `fetch_reference_target/3` no longer raises on them. Previously a
  repo carrying a `refs/entire/*` ref failed **every** subsequent `info/refs`
  (`FunctionClauseError`), taking down clone, fetch and push together.
- `:other` is plumbed through the GraphQL `git_reference_type` enum, the
  `Phoenix.HTML.Safe` impl for `GitRef`, and the branch/tag picker
  (`BranchSelectLive` filters to branches and tags).
- Regression tests: `apps/gitgud/test/gitgud/git_reference_test.exs`.