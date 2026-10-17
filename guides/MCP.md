# AI-Native MCP Server — Design & Implementation Plan

Status: **Phase 6 core implemented** — read + write tool catalog, PAT auth with a
scope gate, settings UI, tool-call telemetry, and client docs. Optional items
(rate limiting, SSE + resources) deliberately not built — see §11.
Owner: gitfrank maintainers
Reference implementation: `~/Code/exhub` (Elixir, `anubis_mcp`-based MCP servers + hub)

---

## 1. Goal

Make gitfrank an **AI-native Git hosting platform** by exposing its domain
(repositories, files, issues, code review, releases, users, search) as a
**Model Context Protocol (MCP) server**, so AI agents (AiderDesk, Claude Code,
Zed, Emacs, …) can read and act on gitfrank over a single standard endpoint.

Concretely, a client connects to **`POST /api/mcp`** (Streamable HTTP), lists
tools, and calls them, e.g.:

```jsonc
// tools/list →
["whoami", "search_repositories", "get_repository", "read_file", "list_issues", …]
// tools/call →
{"name": "create_issue", "arguments": {"owner": "alice", "name": "gitfrank", "title": "…"}}
```

## 2. Non-goals

- Not a replacement for GraphQL; GraphQL stays the typed web/API contract.
- No LLM inference inside gitfrank — gitfrank only **serves** tools.
- Phase 6 (out of scope for v1) covers SSE transport, MCP *resources*/*prompts*,
  and an in-product MCP **client/hub** that lets gitfrank consume upstream MCP
  servers.

## 3. Decisions (agreed)

| # | Decision |
|---|----------|
| 1 | **PAT included** — add persistent personal access tokens (Phase 5) |
| 2 | **Placement** — inside `apps/gitgud_web` (mirrors `GitGud.GraphQL.*`); no new umbrella app |
| 3 | **Transport** — Streamable HTTP only |
| 4 | **Route** — `POST /api/mcp` |
| 5 | **Write tools included** in v1 (authorization-gated) |

### Toolchain (Path A — implemented)

`anubis_mcp` requires Elixir `~> 1.18`, so the project moved from Elixir 1.17.3 to
**1.18.2-otp-27** (`.tool-versions`, `Dockerfile ARG ELIXIR_VERSION`, `AGENTS.md`).
Notes:

- `anubis_mcp "~> 1.14"` added to `apps/gitgud_web/mix.exs` (pulls `finch`, `peri`,
  `mint`, `nimble_*`, `hpax`).
- `peri` (transitive) optionally requires `ecto ~> 3.12`; because gitfrank already
  depends on Ecto, Hex flags a conflict. We keep Ecto 3.9 with an **umbrella-root
  override** (`{:ecto, "~> 3.9", override: true}` in the root `mix.exs`); `peri`'s
  Ecto integration is unused by Anubis and compiles fine against 3.9.
- The Anubis transport is started with `transport: {:streamable_http, [start: true]}`
  so it boots even when Anubis can't detect a running HTTP server (`MIX_ENV=test`,
  where the Phoenix endpoint has `server: false`).

## 4. Reference: the exhub MCP mechanism (what we mirror)

- `anubis_mcp` Hex package (`Anubis.Server`, `Anubis.Server.Component`).
- **Server module** per capability group:
  ```elixir
  use Anubis.Server, name: "…", version: "1.0.0", capabilities: [:tools]
  component(SomeTool)
  def init(_client_info, frame), do: {:ok, frame}
  def handle_request(req, frame), do: ServerHelpers.handle_request_with_filtered_tools(__MODULE__, req, frame)
  ```
- **Tool module** per tool:
  ```elixir
  use Anubis.Server.Component, type: :tool
  def name, do: "…"
  def description, do: "…"
  schema do field(:x, {:required, :string}, description: "…") end
  def execute(params, frame) do
    resp = Response.tool() |> Response.json(%{…})
    {:reply, resp, frame}
  end
  ```
- Mounted as a Plug via a **LazyPlug** (defers `init/1` + auto-creates sessions),
  `transport: :streamable_http`, started as a supervised child.

We copy these **patterns** (not the exhub modules), renamed under `GitGud.MCP.*`.

## 5. Architecture

```
POST /api/mcp
   │
   ▼
GitGud.Web.Router  ── scope "/api" ──► pipe_through :mcp
   │                                      plug :fetch_session
   │                                      plug GitGud.MCP.AuthPlug  (session | bearer | PAT → JSON-RPC 401)
   ▼
forward "/mcp" ─► GitGud.MCP.LazyPlug  (lazy init + session bootstrap)
   ▼
Anubis.Server.Transport.StreamableHTTP.Plug
   ▼
GitGud.MCP.Server  (components: every tool)
   ▼
GitGud.MCP.Tools.*  ──►  GitGud.{Repo,Issue,User,Comment,Review,Release}Query
                          GitGud.RepoPool / GitRekt.GitAgent      (files, refs, commits)
                          GitGud.Authorization                    (policy enforcement)
```

Supervision (`GitGud.Web.Application` children):

```elixir
{GitGud.MCP.Server,
 transport: {:streamable_http, [start: true]},
 request_timeout: 600_000,
 session_idle_timeout: 86_400_000 * 365}
```

## 6. Module & file inventory

| Module | File |
|---|---|
| `GitGud.MCP.Server` | `apps/gitgud_web/lib/gitgud/mcp/server.ex` |
| `GitGud.MCP.ServerHelpers` | `apps/gitgud_web/lib/gitgud/mcp/server_helpers.ex` |
| `GitGud.MCP.LazyPlug` | `apps/gitgud_web/lib/gitgud/mcp/lazy_plug.ex` |
| `GitGud.MCP.AuthPlug` | `apps/gitgud_web/lib/gitgud/mcp/auth_plug.ex` |
| `GitGud.MCP.Tools.*` | `apps/gitgud_web/lib/gitgud/mcp/tools/*.ex` |
| `GitGud.MCP.Tools.Helpers` | `apps/gitgud_web/lib/gitgud/mcp/tools/helpers.ex` |
| `GitGud.MCP.Tools.WhoAmI` | `apps/gitgud_web/lib/gitgud/mcp/tools/who_am_i.ex` |
| `GitGud.MCP.Authorization` (resource + scope gates) | `apps/gitgud_web/lib/gitgud/mcp/authorization.ex` |
| `GitGud.MCP.Telemetry` | `apps/gitgud_web/lib/gitgud/mcp/telemetry.ex` |
| `GitGud.MCP.Telemetry.LoggerHandler` | `apps/gitgud_web/lib/gitgud/mcp/telemetry/logger_handler.ex` |
| `GitGud.PersonalAccessToken` | `apps/gitgud/lib/gitgud/schemas/personal_access_token.ex` |
| `GitGud.PersonalAccessTokenQuery` | `apps/gitgud/lib/gitgud/queries/personal_access_token_query.ex` |
| PAT migration | `apps/gitgud/priv/db/migrations/20261017000000_create_personal_access_tokens.exs` |
| PAT settings controller/view | `apps/gitgud_web/lib/gitgud_web/controllers/token_controller.ex` (+ template) |
| Design doc (this file) | `guides/MCP.md` |
| Client setup guide | `guides/MCP Clients.md` |

## 7. Endpoint & transport

- **Streamable HTTP**, single POST endpoint — `POST /api/mcp`.
- MCP session handled by Anubis (`mcp-session-id` header); `LazyPlug` bootstraps
  sessions for stateless clients.
- `Plug.Parsers` already parses JSON at the Endpoint — no extra plug needed.
- Only `POST` (plus `GET` for the optional SSE probe) is forwarded; everything
  else 405.

## 8. Authentication

A dedicated `:mcp` pipeline in `GitGud.Web.Router`:

```elixir
pipeline :mcp do
  plug :fetch_session
  plug GitGud.MCP.AuthPlug      # bearer(Phoenix.Token) | session | PAT → JSON-RPC 401
end

scope "/api" do
  pipe_through :mcp
  forward "/mcp", GitGud.MCP.LazyPlug, server: GitGud.MCP.Server, request_timeout: 600_000
end
```

Credential order inside `authenticate/2`:

1. `Authorization: Bearer <Phoenix.Token>` — existing short-lived token (24h).
2. `Authorization: Bearer gf_<…>` / `X-Api-Key: gf_<…>` — **PAT** (Phase 5).
3. `:user_id` session cookie — for the browser playground / interactive use.

All paths resolve to `conn.assigns.current_user` via `UserQuery.by_id/1`.

**PAT resolution is deliberately *not* part of `authenticate/2`**: `GitGud.MCP.AuthPlug`
calls `AuthenticationPlug.authenticate_personal_access_token/2` explicitly, so a
personal access token can only be used on the MCP endpoint (it cannot be replayed
against GraphQL/REST, where the PAT scope gate is not applied).

## 9. Authorization & scopes (Phase 5)

Two independent gates; a tool call must pass **both**:

1. **Scope gate** (PAT only) — the token must carry the scope the tool needs.
2. **Resource gate** — `GitGud.Authorization.authorized?(user, resource, action)`
   is always enforced (unchanged domain policy).

### PAT model

`GitGud.PersonalAccessToken`

| Field | Type | Notes |
|---|---|---|
| `id` | `bigint` | PK |
| `user_id` | `bigint` | FK → `users` |
| `name` | `text` | human label ("AiderDesk on laptop") |
| `token_prefix` | `text` | first 12 chars, **unique index** for O(1) lookup |
| `token_hash` | `binary` | `:crypto.hash(:sha256, token)` — tokens are high-entropy |
| `scopes` | `text[]` | e.g. `["issue:read","issue:write"]` |
| `last_used_at` | `utc_datetime` | updated on successful auth |
| `expires_at` | `utc_datetime` | nullable = no expiry |
| `revoked_at` | `utc_datetime` | soft revoke |
| `inserted_at`/`updated_at` | `utc_datetime` | Ecto timestamps |

Token format: `gf_<base32(32 bytes)>`. The plaintext is shown **once** at
creation; only prefix+hash are stored. Never log or return the token.

### Scopes

| Scope | Grants |
|---|---|
| `user:read` | `whoami`, and user results in `search` |
| `repo:read` | repository metadata, refs, trees, blobs, commits, releases, and repository results in `search` |
| `repo:write` | future repo mutations |
| `issue:read` | issues, comments, labels |
| `issue:write` | create/comment/close/reopen/retitle/label issues |
| `review:write` | commit line review comments |

`search` returns both users and repositories, so it requires **both** `repo:read`
and `user:read`; `search_repositories` needs only `repo:read`.

`GitGud.MCP.Authorization` maps every registered tool → its required scope in
the `@tool_scopes` attribute, exposed through `required_scope/1`,
`visible_tool?/2` and `authorize_tool/2`:

- `GitGud.MCP.ServerHelpers.handle_request_with_filtered_tools/3` filters the
  `tools/list` response by scope, and rejects a disallowed `tools/call` with
  `Anubis.MCP.Error.execution("insufficient_scope", %{tool:, required:, granted:})`.
- A `nil` scope list means *unrestricted*; that is how session / `Phoenix.Token`
  bearer credentials are treated (still subject to the resource gate).
- `GitGud.MCP.AuthPlug` resolves credentials in order and assigns
  `conn.assigns.mcp_scopes` from the PAT; Anubis merges the assigns into
  `frame.assigns[:mcp_scopes]`.

Settings UI: `/settings/tokens` (list/create/delete), linked from the profile
nav; the plaintext is rendered exactly once on the `create` response
(`token_html/show.html.heex`) — never in a flash, session or log.

## 10. Tool catalog

**Read-only**

| Tool | Key params | Backing | Action |
|---|---|---|---|
| `whoami` | — | `AuthenticationPlug.current_user/1` | — |
| `search_repositories` | `query`, `limit` | `RepoQuery.search/2` | `:pull` (filtered) |
| `get_repository` | `owner`, `name` | `RepoQuery.user_repo/2` | `:pull` |
| `list_branches` | `owner`, `name` | `RepoPool` → `GitRekt.GitAgent` refs | `:pull` |
| `list_tags` | `owner`, `name` | `GitAgent` tags | `:pull` |
| `get_tree` | `owner`, `name`, `revision`, `path` | `GitAgent` tree | `:pull` |
| `read_file` | `owner`, `name`, `revision`, `path`, `max_bytes` | `GitAgent` blob | `:pull` |
| `get_commit` | `owner`, `name`, `oid` | `GitAgent` commit (+diff stat) | `:pull` |
| `list_issues` | `owner`, `name`, `state`, `labels`, `limit`, `cursor` | `IssueQuery.repo_issues_with_reply_count` | `:pull` |
| `get_issue` | `owner`, `name`, `number` | `IssueQuery.repo_issue` | `:pull` |
| `list_issue_comments` | `owner`, `name`, `number` | `IssueQuery` comments | `:pull` |
| `list_releases` | `owner`, `name`, `limit` | `ReleaseQuery` | `:pull` |
| `search` | `all` \| `user` \| `repo` | `RepoQuery.search` + `UserQuery.search` | `repo:read` + `user:read` |

**Write (authorization-gated; all also require the matching `*:write` scope on a PAT in Phase 5)**

Each write tool mirrors its `GitGud.Web`/GraphQL counterpart and enforces the
**domain's own per-resource policy** via `GitGud.Authorization.enforce_policy/3`
(issue actions: `:comment`, `:close`, `:reopen`, `:edit_title`, `:edit_labels`;
comment actions: `:edit`, `:delete`) rather than a blanket `:push`, so an MCP
call can never exceed what the web UI allows. `create_issue` and
`create_commit_line_review_comment` additionally require a **verified** email
(`GitGud.User.verified?/1`), matching the controllers.

| Tool | Key params | Backing | Gate |
|---|---|---|---|
| `create_issue` | `owner`, `name`, `title`, `body`, `labels`¹ | `GitGud.Issue.create/3` | repo `:pull` + verified |
| `comment_on_issue` | `owner`, `name`, `number`, `body` | `GitGud.Issue.add_comment/3` | `:comment` |
| `update_issue_title` | `owner`, `name`, `number`, `title` | `GitGud.Issue.update_title/3` | `:edit_title` |
| `update_issue_labels` | `owner`, `name`, `number`, `push`¹, `pull`¹ | `GitGud.Issue.update_labels/3` | `:edit_labels` |
| `close_issue` | `owner`, `name`, `number` | `GitGud.Issue.close/2` | `:close` |
| `reopen_issue` | `owner`, `name`, `number` | `GitGud.Issue.reopen/2` | `:reopen` |
| `update_comment` | `owner`, `name`, `comment_id`, `body` | `GitGud.Comment.update/3` | `:edit` |
| `delete_comment` | `owner`, `name`, `comment_id` | `GitGud.Comment.delete/1` | `:delete` |
| `create_commit_line_review_comment` | `owner`, `name`, `commit_oid`, `blob_oid`, `hunk`, `line`, `body` | `GitGud.CommitLineReview.add_comment/8` | repo `:pull` + verified |

¹ Labels are given by **name** (comma-separated) and resolved against the
repository's labels; `create_issue`'s `body` is required (the domain requires a
non-empty initial comment).

All tool results are JSON envelopes: `{"ok": true, "data": …}` or
`{"ok": false, "error": "…", "detail": …}` — never a raw secret. Unknown or
unreadable targets are reported as `not_found`; a policy denial as `forbidden`;
validation failures as `error: "validation_error"` with a `detail` map.

## 11. Phases

### Phase 0 — Plan (this document) ✅
Deliverable: `guides/MCP.md`.

### Phase 1 — Foundation & reachable endpoint ✅
- Add `{:anubis_mcp, "~> 1.14"}` to `apps/gitgud_web/mix.exs`.
- Config: `:gitgud_web, :mcp` (see §12); runtime env `MCP_ENABLED`, `MCP_PATH`.
- `GitGud.MCP.Server` (empty toolset), `ServerHelpers`, `LazyPlug`,
  `GitGud.Web.MCPPlug`.
- Router: `:mcp` pipeline + `scope "/api"`, `forward "/mcp"`.
- Start `GitGud.MCP.Server` in `GitGud.Web.Application`.

**Acceptance:** `POST /api/mcp` with a valid session answers an `initialize`
handshake and `tools/list` returns `[]` (or the not-yet-added set) without error.
`MIX_ENV=test mix test` stays green.

### Phase 2 — Authentication ✅
- `:mcp` pipeline: `fetch_session` → `GitGud.MCP.AuthPlug` (bearer / session;
  PAT added in Phase 5).
- 401 JSON-RPC error shape (`-32001`) + `WWW-Authenticate` challenge for
  unauthenticated calls.
- `whoami` tool proving the resolved user reaches the tool frame
  (`frame.assigns[:current_user]`).

**Acceptance:** unauthenticated → 401; bearer/session → `whoami` works.

### Phase 3 — Read tools ✅
- `GitGud.MCP.Authorization` (resource gate only, initially).
- `GitGud.MCP.Tools.Helpers` (JSON envelope, input clamping, struct serializers).
- All read-only tools from §10 + tests.

**Acceptance:** each read tool returns correct data for a fixture repo and is
refused for a private repo without `:pull`.

Implementation notes:
- **Object ids** travel as raw binaries inside GitRekt; tools format them with
  `GitRekt.Git.oid_fmt/1` (`Helpers.oid/1`, byte-size guarded) on the way out and
  parse hex input with `GitRekt.Git.oid_parse/1` (`Helpers.parse_oid/1`) on the way in.
- `Helpers.reply/2` normalises `{:ok, data} | {:error, reason}` into the JSON
  envelope; `error/2` stringifies any reason (including `GitRekt.GitError` structs).
- The read tools carry the resource gate (`Authorization.enforce/3` → `:pull`); the
  PAT scope gate lands in Phase 5.

### Phase 4 — Write tools ✅
- All write tools from §10, each preceded by the domain resource gate.

**Acceptance:** authorized create/comment/close succeed; unauthorized → `:forbidden`.

Implementation notes:
- `GitGud.MCP.Tools.Helpers` gained `fetch_issue/3` (repo + issue in one step),
  `ensure_verified/1`, `resolve_labels/2` (names → `GitGud.IssueLabel` structs),
  `changeset_errors/1`, and an `issue_ref/1` serializer.
- `GitGud.MCP.Authorization.fetch_repo/4` forwards preloads (e.g.
  `preload: [:issue_labels]`) so write tools can resolve label names.
- The resource gate uses the issue/comment policy actions (`:comment`, `:close`,
  `:reopen`, `:edit_title`, `:edit_labels`, `:edit`…), mirroring the GraphQL
  resolvers; `create_issue` / `create_commit_line_review_comment` also require a
  verified email. No write tool bypasses an existing policy.
- The PAT scope gate was added in Phase 5 (see `GitGud.MCP.Authorization`);
  session/bearer credentials remain full-scope.

### Phase 5 — Personal access tokens ✅
- `GitGud.PersonalAccessToken` schema (prefix + SHA-256 hash, `scopes`, soft
  `revoked_at`, optional `expires_at`) and `GitGud.PersonalAccessTokenQuery`
  (`by_id/2`, `by_prefix/2`, `user_tokens/2`, `authenticate/1`, `touch/1`).
- Migration `20261017000000_create_personal_access_tokens.exs` (unique index on
  `token_prefix`, index on `user_id`); `User` gained
  `has_many :personal_access_tokens` (cascade delete).
- `AuthenticationPlug.authenticate_personal_access_token/2` (bearer `gf_…` or
  `X-Api-Key`, constant-time hash compare, revoked/expired rejection, updates
  `last_used_at`).
- `GitGud.MCP.Authorization` scope gate (`@tool_scopes` → `required_scope/1`,
  `visible_tool?/2`, `authorize_tool/2`) wired into
  `GitGud.MCP.ServerHelpers`; `GitGud.MCP.AuthPlug` assigns `:mcp_scopes`.
- `/settings/tokens` `TokenController` + `TokenHTML` (`index`/`new`/`create`/
  `delete`) + `Personal access tokens` nav item; plaintext shown once.

**Acceptance:** create a PAT in the UI → `curl -H "Authorization: Bearer gf_…"
/api/mcp` authenticates; a token lacking the tool's scope sees the tool omitted
from `tools/list` and gets `insufficient_scope` on `tools/call`; a revoked or
expired token gets a JSON-RPC 401.

Two notes from implementation: (a) `Ecto.Changeset.cast/3` discards an empty
list for `{:array, _}` fields, so `PersonalAccessToken.changeset/2` validates the
*field value* (`validate_scopes/1`) instead of the cast change; (b) `phoenix_html`
3.3 has no `multiple_checkbox/3`, so `new.html.heex` uses plain
`<input type="checkbox" name="token[scopes][]">` and the controller strips the
empty submission.

### Phase 6 — Docs, examples, hardening ✅ (core)
- Client-setup guide — `guides/MCP Clients.md`: token creation + scope presets,
  a `curl` handshake smoke test, and config snippets for AiderDesk
  (`mcp-servers.json`), Claude Code (`claude mcp add --transport http` /
  `mcpServers`), Zed (`context_servers` + `mcp-remote`) and any Streamable HTTP
  client, plus a troubleshooting table.
- `AGENTS.md` §11 — MCP section (layout, auth, scopes, config, telemetry, tests).
- **Telemetry** — `GitGud.MCP.Telemetry.span/2` wraps every `tools/call` at the
  single choke point in `GitGud.MCP.ServerHelpers`, emitting
  `[:gitgud, :mcp, :tool, :call, :start | :stop]` (`:stop` measurements
  `%{duration: native}`; metadata `%{tool:, result: :ok | :error | :denied,
  user_id:, scopes:, session_id:, remote_ip:}`). `GitGud.Web.Application`
  attaches `GitGud.MCP.Telemetry.LoggerHandler` unless
  `:gitgud_web, :mcp, :telemetry` is `false`. A `:denied` result is the scope
  gate rejecting the call before the tool runs.
- Deliberately **not** built (still optional): request rate limiting and
  MCP `resources` / SSE streaming. The endpoint is stateless per-request and the
  scope + resource gates already cap what a token can do, so these are
  additive hardening rather than correctness fixes.

## 12. Configuration

```elixir
# apps/gitgud_web/config/config.exs
config :gitgud_web, :mcp,
  enabled: System.get_env("MCP_ENABLED", "true") == "true",
  path: System.get_env("MCP_PATH", "/api/mcp"),
  server_name: "gitfrank",
  server_version: "1.0.0",
  request_timeout: 600_000,
  session_idle_timeout: 86_400_000 * 365,
  telemetry: true
```

`enabled`, `path`, `server_name` and `server_version` are resolved at **build
time**: the router mounts the endpoint through `Application.compile_env/3` and
the server module derives its identity at compile time, so they are *not*
runtime-tunable. `MCP_ENABLED=false` compiles the endpoint out; `MCP_PATH`
relocates it (default `/api/mcp`).

When `enabled: false`, the `:mcp` pipeline/route is not mounted and the server
child is not started. `telemetry: false` keeps the `[:gitgud, :mcp, :tool, :call]`
events flowing but detaches `GitGud.MCP.Telemetry.LoggerHandler` (the debug
logger); the span itself is always emitted from `GitGud.MCP.ServerHelpers` so
external handlers keep working.

Client setup (token creation, `curl` smoke test, AiderDesk / Claude Code / Zed
configs, troubleshooting) lives in **[`guides/MCP Clients.md`](MCP%20Clients.md)**.
The minimal shape is:

```json
{ "mcpServers": { "gitfrank": {
  "type": "streamable_http",
  "url": "https://<host>/api/mcp",
  "headers": { "Authorization": "Bearer gf_…" }
} } }
```

## 13. Testing strategy

- **Tool unit tests** — build the Anubis schema from `GitGud.MCP.Server`, call
  `execute/2` with a `frame` carrying `%{current_user: user, scopes: [...]}`, assert
  the JSON envelope and authorization failures. Pure, `async: true`.
  Read tools: `test/gitgud/mcp/tools_test.exs`; write tools:
  `test/gitgud/mcp/write_tools_test.exs`.
- **Schema/query tests** — `apps/gitgud/test/gitgud/personal_access_token_test.exs`
  (token generation, prefix/hash, revoked/expired, `authenticate/1`).
- **PAT auth & scope gate (endpoint)** —
  `apps/gitgud_web/test/gitgud/mcp/personal_access_token_auth_test.exs`: exercises
  the real `POST /api/mcp` transport for bearer / `X-Api-Key` / session auth,
  revoked & expired rejection, `tools/list` scope filtering and the
  `insufficient_scope` `tools/call` error.
- **Settings controller** —
  `apps/gitgud_web/test/gitgud_web/controllers/token_controller_test.exs`.
- **Auth plug tests** — `GitGud.Web.ConnCase`, cover session/bearer/PAT/revoked/expired/wrong-scope.
- **Endpoint test** — POST `/api/mcp` with a JSON-RPC `initialize` then `tools/call`
  for `whoami`; assert the Streamable HTTP response.
- **Telemetry** — `apps/gitgud_web/test/gitgud/mcp/telemetry_test.exs` attaches a
  test handler to `GitGud.MCP.Telemetry.event_prefix() ++ [:start | :stop]`, drives
  an allowed `tools/call` (expects `result: :ok`) and an out-of-scope one (expects
  `result: :denied`), and asserts `Telemetry.span/2` returns the wrapped value
  unchanged. `GitGud.MCP.Telemetry.LoggerHandler` stays attached under
  `MIX_ENV=test`, so the endpoint tests cover it indirectly.
- **Migration** — the PAT table + unique prefix index run against the Postgres
  container via `MIX_ENV=test mix ecto.migrate` (part of the `test:` alias).
- Run with `MIX_ENV=test mix test` (see `AGENTS.md` §5/§7).
- Client-facing instructions (token creation, `curl` smoke test, editor configs,
  troubleshooting) live in [`guides/MCP Clients.md`](MCP%20Clients.md).

Verification baseline after Phase 6: `gitgud` 137 tests / 0 failures / 12 skipped;
`gitgud_web` 156 tests / 0 failures / 4 skipped; `mix format --check-formatted`
clean on every touched file.

## 14. Risks / open questions

| Risk | Mitigation |
|---|---|
| `anubis_mcp` version/API drift vs exhub's 1.14 | Pin `~> 1.14`; copy exhub's LazyPlug/ServerHelpers verbatim, adjust names only |
| Streamable HTTP session semantics for stateless clients | LazyPlug auto-session bootstrap (proven in exhub) |
| PAT hashing: SHA-256 vs Argon2 | SHA-256 is safe here (≥256-bit random tokens); keeps auth O(1) |
| Scope ↔ existing policy mismatch | Scope gate is additive; resource gate always runs, so no privilege escalation |
| Large files/trees in tool output | `max_bytes`/`limit` caps + truncation markers |
| `repo:write` scope unused in v1 | Reserved for future repo mutations |

## 15. First increment (on approval)

Phase 1 only: dependency, config, `GitGud.MCP.Server` (empty), `ServerHelpers`,
`LazyPlug`, `MCPPlug`, `:mcp` pipeline + `/api/mcp` route, supervision child,
plus the smoke test. Nothing user-visible changes.