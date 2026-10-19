# Sessions & Checkpoints — Design & Implementation Plan

Status: **Phases 0–6 implemented** — research complete; reference classification fixed
and covered by tests; the whole `entire` → gitfrank checkpoint-sync loop has been run against
a live dev server (§11), which also turned up — and fixed — a pre-existing SSH transport bug
(§12); the domain ingest layer — `GitGud.Checkpoints` plus the `GitGud.MetaDB` index — is
implemented and covered by tests (§6, Phase 1); the repository **Sessions** tab — the
checkpoint list, the checkpoint detail (prompt, transcript, files touched, diff, tasks) and the
commit provenance chips — is implemented and covered by tests (§6, Phase 2); and the APIs —
GraphQL (`checkpoint`, `repo.checkpoints`/`checkpoint`, `commit.checkpoints`) and three MCP
tools (`list_checkpoints`, `get_checkpoint`, `search_checkpoints`) — are implemented and
covered by tests (§6, Phase 3); and search & provenance is done — a droppable prompt term
index in `GitGud.MetaDB` (`Checkpoints.search/3`), blame-style provenance
(`Checkpoints.provenance/3`), a `?q=` search box on the Sessions tab, a `search_checkpoints`
connection and a `checkpoint_provenance` connection on GraphQL `repo`, and the
`checkpoint_provenance` MCP tool (§6, Phase 4); and Phase 5 hardened the feature — deletions
heal the index on their own, an admin-only storage report sits on the Sessions tab, a push-side
guard keeps the `refs/entire/*` namespace well-formed, and every read accepts an unambiguous
short id; and Phase 6 made the checkpoint detail actually readable — the transcript is now read
from the CLI's normalised file and rendered as messages, tool calls and all (§6, Phase 6); and
Phase 7 extended the renderer to agent-native *document* transcripts (AiderDesk), which carry no
compact form at all (§6, Phase 7) — leaving only the optional control plane (§8 level B) undone.
Owner: gitfrank maintainers
External reference: the [Entire CLI](https://github.com/entireio/cli) (`entire.io`) and its
docs under `docs/architecture/` (`sessions-and-checkpoints.md`, `ref-checkpoint-backend.md`,
`upstream-host-resolution.md`).

---

## 1. Goal

gitfrank should capture, store and serve **AI coding-agent sessions** alongside code, the
way entire.io does — and, above all, be usable as the **git remote an `entire`-enabled
repository pushes to**.

Concretely, once this lands:

- A developer runs `entire enable` in a repo whose remote is gitfrank (or adds gitfrank as
  a remote). Their agent's prompts, tool calls, transcripts and files-touched are captured
  as **checkpoints** and pushed to gitfrank as ordinary git refs.
- gitfrank's web UI shows a **Sessions / Checkpoints** view per repository: for each
  commit, *why* it changed — the prompt, the transcript, the files touched, the token
  usage — traceable back from any commit.
- gitfrank's **GraphQL API** and **MCP server** expose the same data, so agents can search
  "how was this done before" instead of re-deriving it.

The headline is compatibility: **the Entire CLI needs no server API to sync checkpoints**
— it pushes git refs. So "compatible with the entireio CLI directly" reduces, in the first
instance, to *being a correct git server for `refs/entire/*`, and then surfacing what
arrives*.

## 2. Non-goals (at least for v1)

- **Not** a re-implementation of the Entire control plane (`entire login`, `org`/`project`/
  `repo`, `activity`/`search`/`trail`, the `entire://` remote helper). That is an
  OIDC-style HTTP API with `/.well-known` discovery; see §10 for why it is deferred.
- **No** changes to the agent-hook side — gitfrank never installs hooks or talks to an
  agent's transcript files. gitfrank is a *reader* of what the CLI pushes.
- **No** LLM inference inside gitfrank. Semantic/agentic search is a retrieval problem
  over stored transcripts, not a generation problem.
- **No** new umbrella app. This lives in `:gitgud` (domain) + `:gitgud_web` (UI/API),
  like the MCP server does.

## 3. Background: the Entire data model

This section paraphrases the upstream design so the plan is self-contained.

### 3.1 Sessions and checkpoints

- A **session** is one agent conversation, from first hook to session end. Its live state
  lives in the clone (`.git/entire-sessions/<id>.json`, `.entire/metadata/<id>/`) and is
  *never* written to git until a commit happens.
- A **checkpoint** is the permanent record of a session's work at a commit. It is linked
  to the commit by an **`Entire-Checkpoint: <id>` trailer** in the commit message.
- Checkpoint IDs are **26-character ULIDs** (Crockford base32, lexicographically
  time-sortable). Older checkpoints use a legacy **12-char hex** id; both stay readable.

### 3.2 Storage: independent refs

The current backend (`git-refs`, the default for new setups) stores **one git ref per
checkpoint**:

```
refs/entire/checkpoints/<shard>/<id>       # <shard> = last two characters of <id>
```

Each ref points at a commit whose **tree root is the checkpoint subtree** (the ref accretes
its own per-checkpoint history, so writes are fast-forward-only). Layout of that tree:

```
metadata.json              # CheckpointSummary — see below
0/                         # first session (0-based)
  metadata.json            #   session-scoped Metadata
  full.jsonl               #   agent transcript, sanitized + redacted (resume/explain)
  transcript.jsonl         #   compacted session
  prompt.txt               #   checkpoint-scoped user prompts
  content_hash.txt         #   sha256 of full.jsonl (dedup short-circuit)
1/ …                       # further sessions in the same checkpoint
tasks/<tool-use-id>/       # subagent records, materialized at condensation
  task.json
  agent-<agent_id>.jsonl
```

`metadata.json` at the root carries (abridged):

```jsonc
{
  "checkpoint_id": "01K9TQ8ZP7X3F5M2WVJ4CNRB6D",
  "strategy": "manual-commit",
  "branch": "main",
  "commit_sha": "…",
  "checkpoints_count": 281,
  "files_touched": ["…"],
  "sessions": [ { "…": "one entry per session dir" } ]
}
```

A legacy `git-branch` backend instead stores the same trees under
`entire/checkpoints/v1` sharded as `<id[:2]>/<id[2:]>/`. Both share the tree layout; only
the *location* differs. gitfrank should read **refs first, then fall back to the branch**.

### 3.3 Transport: ordinary git

- A pre-push hook drains a push queue and **fast-forward-pushes the checkpoint refs** to
  the single *elected* checkpoint-sync remote (`strategy_options.checkpoint_push_remote`,
  else a captured election, else `origin`, else the sole remote). Failures never block the
  user's push.
- Reads `git fetch` a single ref on demand. `entire status` shows the destination and the
  unpushed count.
- A dedicated `checkpoint_remote` (`{provider: github|gitlab, repo: org/repo}`) can point
  checkpoint data at a *separate* repository.

**Nothing here requires authentication to a control plane.** Authentication is whatever
the git remote already uses (SSH key or HTTPS credentials).

### 3.4 The part that does need a server

`entire login`, `org`/`project`/`repo`, `activity`/`search`/`trail` and the
`git-remote-entire` helper (`entire://<cluster>/gh/<owner>/<repo>`) talk to a **core**
(identity + control plane) that mints JWTs, and to **resource servers** that advertise
which cores they trust via `/.well-known/entire-cluster.json` (`core_urls`) or
`/.well-known/entire-api.json` (`trusted_issuers`). The control-plane API is described by
a ~600 KB OpenAPI document (`internal/coreapi/spec/core.openapi.json`).

## 4. Current state of gitfrank (feasibility)

| Concern | Where | Status |
|---|---|---|
| Receive any ref name on push | `GitRekt.WireProtocol.ReceivePack.push_cmd/2` — `reference_create(agent, name, :oid, oid)`, no allowlist | ✅ already works |
| Persist push to the domain | `GitGud.Repo` `defimpl GitRekt.GitRepo` → `push/2` (bumps `pushed_at`) | ✅ hook point exists |
| Advertise refs on `info/refs` | `WireProtocol.reference_discovery/3` lists **all** refs (`glob: :undefined`), `format_ref_line/1` emits `prefix <> name` | ⚠️ see blocker |
| Classify a ref | `GitAgent.resolve_reference_type/1` — **only** `refs/heads/` and `refs/tags/` | ❌ **blocker** |
| Expose refs to UI/API | `GitGud.Repo.branches/1`, `tags/1` only | ❌ missing |
| Derived-data store | `GitGud.MetaDB` (CubDB key/value, needs `:data_dir`) | ✅ available |

### 4.1 The blocker (fixed in Phase 0 — see §6)

`resolve_reference_type/1` (`apps/gitrekt/lib/gitrekt/git_agent.ex`) has two clauses:

```elixir
defp resolve_reference_type("refs/heads/"), do: :branch
defp resolve_reference_type("refs/tags/"), do: :tag
```

`reference_discovery/3` streams **every** ref through `resolve_reference_peel!/3`, which
calls `resolve_reference/1`, which calls `resolve_reference_type/1`. Any ref outside
`refs/heads/` and `refs/tags/` therefore raises `FunctionClauseError`.

Consequence, and why this is urgent rather than cosmetic:

1. The **first** push of a `refs/entire/checkpoints/…` ref succeeds (discovery runs before
   the ref exists).
2. Every **subsequent** push or fetch runs discovery with that ref present → the whole
   `info/refs` response crashes. The repository becomes **un-clonable and un-pushable**.

So hosting checkpoints without this fix is worse than not hosting them. It is a one-line
catch-all plus tests.

## 5. Architecture of the feature

```
                     push  refs/entire/checkpoints/<shard>/<id>
  entire CLI  ───────────────────────────────────────────────►  gitfrank
                                                               │
             receive-pack writes the ref (already works)  ◄────┘
                                                               │
                     GitGud.Checkpoints  (read/index)  ◄───────┤  reads the ref tree
                                                               │
        ┌──────────────────────────┬───────────────────┬───────┴────────────────┐
        │                          │                   │                        │
   MetaDB cache            GraphQL types        MCP tools            LiveView (Sessions tab)
   (derived index)         (checkpoint…)        (list/get/search)    (list + detail)
```

Principles:

- **Git is the source of truth.** Checkpoints are read out of the repository's own object
  store through `GitGud.RepoPool`; nothing is duplicated into Postgres. MetaDB holds only
  a *cache/index* that can be dropped and rebuilt.
- **Read-through, not run-ahead.** A repository with no checkpoint refs costs nothing.
- **Authorization is the existing repo authorization.** A checkpoint is as private as the
  code it describes.

## 6. Phases

### Phase 0 — Transport safety ✅ done

Foreign ref names now classify as `:other` instead of raising:

- `GitRekt.GitAgent.resolve_reference_type/1` got the catch-all clause
  (`apps/gitrekt/lib/gitrekt/git_agent.ex`), and the `GitRekt.GitRef` type union was
  widened to `:branch | :tag | :other` (`apps/gitrekt/lib/gitrekt.ex`).
- `fetch_reference_target/3` got the matching clause: a ref outside `refs/heads/` and
  `refs/tags/` points directly at a commit, so it is returned as-is (branches behave the
  same way) rather than peeled.
- `:other` is plumbed through the three places that enumerate reference types:
  the GraphQL `git_reference_type` enum (`types.ex`), the `Phoenix.HTML.Safe` impl for
  `GitRef` (`apps/gitgud_web/lib/gitrekt.ex`), and `BranchSelectLive` — which now filters
  its ref list (and its tab resolution) to branches and tags, since it reads *all* refs.
- Regression tests: `apps/gitgud/test/gitgud/git_reference_test.exs` — classification,
  `references/1` listing, exclusion from `branches/1`, advertisement by
  `WireProtocol.reference_discovery/3`, `with: :commit` resolution, and HEAD still
  resolving.

The "second push crashes" case, and the rest of the loop, are now **verified against a
real `entire enable`-ed clone** — push → ref advertisement → clone → fetch, all green. See
§11 for the exact commands and observed output. Validation also exposed an unrelated,
pre-existing SSH transport bug (§12).

### Phase 1 — Ingest & index (`:gitgud`) ✅ done

`GitGud.Checkpoints` (`apps/gitgud/lib/gitgud/checkpoints.ex`) reads checkpoints straight out
of the repository's own object store through `GitGud.RepoPool`. Nothing is duplicated into
Postgres; `GitGud.MetaDB` holds only a droppable cache.

| Function | Behaviour |
|---|---|
| `enabled?/0` | `config :gitgud, GitGud.Checkpoints, enabled:` gate. While off, the *browse* reads (`list/2`/`refresh/2`, `search/3`, `provenance/3`, `storage/1`) return nothing and `hidden_reference_prefixes/0` hides the namespace, while the *single-checkpoint* reads (`get/2`, `session/4`, `tasks/2`, `prompts/2`, `commit_ids/2`, `for_commit/2`) are deliberately **not** gated &mdash; a direct read still resolves one out of the object store, but the push guard refuses new writes (Phase 5, 5C). |
| `list/2`, `refresh/2` | summarised checkpoints, newest first. `refresh/2` is `list(repo, cache: false)`. |
| `get/2` | one checkpoint's summary plus its raw root `metadata.json` under `:metadata`. |
| `session/4` | `<index>/metadata.json`, `prompt.txt`, and `full.jsonl` — falling back to `transcript.jsonl` — as a list of raw lines (JSON Lines, *or* the lines of one pretty-printed JSON document; see Phase 7). |
| `tasks/2` | `tasks/*/task.json`, each as `%{id, path, data}`. |
| `prompts/2` | the numeric `<index>/prompt.txt` of every session (`%{index, prompt}`, prompt `nil` when absent) without reading a transcript — added in Phase 3 for `search_checkpoints`. |
| `commit_ids/2` | the `Entire-Checkpoint:` trailers of a commit message; a merge commit yields none. |
| `for_commit/2` | `commit_ids/2`, each resolved through `get/2`. |
| `invalidate/1` | drops the cached index for a repository. |

Details worth knowing:

- **One index document per repository**, under `{:checkpoints, owner_login, name}` — *not* the
  `{:checkpoints, repo_id, id}` first sketched here. `MetaDB.get/1` coerces its value into the
  `MetaObject` struct (`struct/2` then raises on any other key set), so per-id keys would have
  needed a new range-scan API for no benefit; adding `MetaDB.get_raw/1` and `MetaDB.delete/1`
  was cheaper. The key is owner/name rather than `repo.id` because MetaDB is process-wide and
  outlives the sandboxed, rolled-back rows of a test run, while `repo.volume` is the *volume*
  id and therefore shared by every repository.
- **The document is `%{watermark, checkpoints}`**, the watermark being a
  `%{ref_name => target_oid}` map built from a single `GitAgent.references/1` listing. Every
  read recomputes that map and rebuilds only on a mismatch, so a force-push, a ref move or a
  ref deletion heals itself with no push-time work; `GitRekt.GitRepo.push/2` additionally drops
  the cache eagerly when a command touches `refs/entire/`.
- **Transcripts are never cached** — `get/2`, `session/4` and `tasks/2` always read Git. The
  `:gitrekt` NIF has no streaming blob read, so `session/4` caps the transcript
  (`max_transcript_bytes`, default 1 MiB) with a `truncated?` flag and drops the last, partial
  line so every returned line is whole. Real streaming needs a new NIF call.
- **The legacy branch is first-class.** Its tip comes out of the same reference listing (no
  `revision/2` lookup for a branch that may not exist), then is walked two levels for
  `<shard>/<rest>/`; those checkpoints report `source: :branch` and their branch tip in the
  watermark.
- **Configuration** (`apps/gitgud/config/config.exs`): `enabled: true`,
  `legacy_branch: "entire/checkpoints/v1"`, `max_transcript_bytes: 1_048_576`.
- The reverse `commit_sha => [checkpoint]` map originally planned for the index was **dropped**:
  `commit_ids/2` reads the trailer off the commit itself, which is authoritative and needs no
  index, and nothing in Phases 1–2 yet needs the bulk form.
- A checkpoint whose `metadata.json` cannot be read is skipped with a `Logger.warning` rather
  than failing the whole listing.

### Phase 2 — UI (`:gitgud_web`) ✅ done

Two live routes inside the existing `live_session :repo` (so the repo layout and its
authorization gate apply unchanged):

```elixir
live "/sessions",     CheckpointLive, :sessions, as: :sessions
live "/sessions/:id", CheckpointLive, :session,  as: :sessions
```

`GitGud.Web.CheckpointLive` (`apps/gitgud_web/lib/gitgud_web/live/checkpoint_live.ex`) carries
both actions; the two route actions are `:sessions`/`:session` rather than `:index`/`:show`
because `CodebaseView.title/2`'s first clause already guards on `action == :show`.

- **List** (`:sessions`): checkpoints newest first — short id (→ detail), recorded-at
  (`{relative}`), branch, linked commit (→ `/commit/<sha>`), files-touched count, sessions
  count, token usage. Offset pagination (`?p=`, 20/page) over the in-memory list, which is
  cheap because the index is MetaDB-cached.
- **Detail** (`:session`): prompt (`markdown_safe/1`), a session selector (`?session=`) when the
  checkpoint has more than one, the transcript as a **100-message window** (`?page=`) over the
  lines `Checkpoints.session/4` returns, normalised to messages by `GitGud.Web.CheckpointTranscript`
  (Phase 6, extended in Phase 7) with the message count and `truncated?` flag shown — a whole
  transcript is never materialised, in the LiveView or the index; files touched; the
  subagent task table; and a **compact diff** against the linked commit (`metadata["commit_sha"]`),
  resolving the commit and its first parent in one `GitAgent.transaction` and rendering changed
  files with `+`/`-` counts plus a link to the full commit page. `CommitDiffLive`'s hunk renderer
  is deliberately *not* duplicated.
- **Empty state**: a repository with no checkpoint refs explains how to turn Entire on
  (`entire enable` / commit / `git push`); when `Checkpoints.enabled?()` is false the tab says so.
  Unreadable checkpoints degrade to the list, and an unknown id redirects back to the list with a
  flash — no dead UI, no crash.
- **Provenance chips**: `CommitHistoryLive` builds a `%{commit_sha => [checkpoint]}` map from
  **one** `Checkpoints.list/2` call in `mount/3` and renders a chip per linked checkpoint in each
  commit row; `CommitDiffLive` calls `Checkpoints.commit_ids/2` for the commit it is showing. Both
  link to `/sessions/<id>`.
- **Tab**: `repo_header/1` gained a **Sessions** entry, active when the live helper is
  `:checkpoint_live` — so the tab lights up for both actions.
- Reuses `GitGud.Web.Markdown`, `GitGud.Web.DateTimeFormatter` and `CodebaseView.title/2` (which
  gained `:sessions`/`:session` clauses) instead of new helpers.

Implementation notes:

- The list shows no agent/model: those live in each session's `<i>/metadata.json`, not the root
  `metadata.json` (confirmed against the real §11 capture), so surfacing them per row would mean N
  extra blob reads. The detail view has them available, and Phase 6 shows them in the transcript
  toolbar.
- Visibility is the repository's, via the same `RepoQuery.user_repo_query` gate the codebase uses
  — see risk 1 in §7.

### Phase 3 — APIs ✅ done

**GraphQL** (`apps/gitgud_web/lib/gitgud/graphql/types.ex` + `resolvers.ex`):

- `object :checkpoint` — `id`, `oid` (the ref's 40-character target), `ref`, `source`
  (`enum :checkpoint_source`, `REF`/`BRANCH`), `branch`, `strategy`, `checkpoints_count`,
  `files_touched`, `session_count`, `sessions` (the raw `metadata.json` entries), `token_usage`,
  `commit_sha`, `committed_at`, `metadata` (the raw root `metadata.json`, resolved only for a
  single checkpoint) and `url` (→ `/owner/name/sessions/<id>`).
- `object :repo` gained `checkpoints(first:, after:, …)` (a connection) and `checkpoint(id:)`;
  `object :git_commit` gained `checkpoints` — the commit's provenance chips, driven by
  `Checkpoints.for_commit/2` through the `:repo` in the resolution context.
- New resolvers `repo_checkpoints/2`, `repo_checkpoint/3`, `commit_checkpoints/2` and
  `checkpoint_url/3`; the two connections reuse the existing `slice_stream/2` +
  `Absinthe.Relay.Connection.from_slice/3` pattern that `repo_tags/2` established.
- `scalar :json` was added: absinthe 1.7's `Absinthe.Type.Custom` carries `datetime`,
  `naive_datetime`, `date`, `time` and `decimal`, but no JSON scalar.
- `oid` and `commit_sha` are `String`, not `:git_oid`: `GitGud.Checkpoints` yields 40-character
  hex, while the `git_oid` scalar *serializes* with `Git.oid_fmt/1`, which expects the raw 20-byte
  form. Converting would mean calling the `oid_parse` NIF, whose `raise`-only stub makes Elixir
  1.18 infer `none()` and emit spurious "incompatible types" warnings at the call site.
- No Relay `node` module and no `to_relay_id/2`: a checkpoint id is a ULID string, and
  `Schema.from_relay_id/1` coerces the decoded id with `String.to_integer/1`. A `connection
  node_type:` works with a plain `object` — `git_reference` already relies on that.
- `GitGud.GraphQL.SchemaGenerator` regenerates the SDL when either module's checksum changes,
  but `apps/gitgud_web/priv/graphql/schema.graphql` is **gitignored**
  (`apps/gitgud_web/.gitignore:27`), so it is not part of the change.

**MCP** (`apps/gitgud_web/lib/gitgud/mcp/tools/{list,get,search}_checkpoints.ex`), following the
existing read-tool pattern (`Authorization.fetch_repo/3` → `GitGud.Checkpoints` →
`Helpers.reply/2`; `repo:read`, no new scope) and serialised by a new `Helpers.checkpoint/1`:

- `list_checkpoints(owner, name, limit, offset)` — the summaries, newest first.
- `get_checkpoint(owner, name, id, session?, max_bytes?)` — the summary plus the raw
  `metadata.json` and the subagent tasks; with `session: N` it also returns that session's
  `prompt` and `transcript` (capped by `max_bytes`, `truncated` flag included). An unbounded
  transcript is never returned.
- `search_checkpoints(owner, name, query, limit, include_transcripts?)` — matches the id, branch,
  strategy, touched files and commit, plus every session prompt via the new
  `Checkpoints.prompts/2` (which reads `prompt.txt` without touching a transcript); with
  `include_transcripts: true` it also scans the transcripts of the 10 most recent checkpoints.
  The scan is capped at 100 checkpoints — a real index is Phase 4.

`GetCheckpoint`'s `session`/`max_bytes` and `SearchCheckpoints`'s caps are the answer to risk 3
in §7: the tools are the first consumer that could otherwise return megabytes.

### Phase 4 — Search & provenance ✅ done

Search is **prompt-only and index-backed**; a transcript is never indexed or scanned unless a
caller explicitly asks for it. Both queries are answered from the checkpoint index already in
`GitGud.MetaDB` — `Checkpoints.search/3` reads no Git at all beyond the one reference listing
`list/2` shares, and `Checkpoints.provenance/3` reads no Git at all.

- **The index document grew a third key.** `{:checkpoints, owner_login, name}` now holds
  `%{watermark, checkpoints, terms}` (`terms` added in Phase 4). `terms` is an inverted index,
  `term => [{checkpoint id, session index}]`, built at the same time as the summaries from the
  session prompts `<i>/prompt.txt`, and dropped with the rest of the document when the
  watermark mismatches. It is a *cache*: a repository with no checkpoint refs costs nothing.
- **Query semantics** — a query is tokenised the same way the index is: lowercased `[a-z0-9]+`
  runs, stop words and one-character terms dropped (at most 16 terms for a query, 64 indexed
  per prompt, each prompt text truncated to 4 KiB, each term's posting list capped at 500
  checkpoints). A checkpoint matches only when **every** term hits: the *summary* fields (`id`,
  `branch`, `strategy`, `commit_sha`, `files_touched` — case-insensitive substring) or an
  *indexed prompt* term. `matched` labels the fields that matched — `"id"`, `"branch"`,
  `"strategy"`, `"commit_sha"`, `"files_touched"` or `"session <n> prompt"` — and the score
  weights a prompt or touched-file match at 3 and the rest at 1, tie-broken by recency and id.
  The hard-`AND` is deliberate: it keeps precision up and the postings cheap, and a caller can
  always narrow by adding a term.
- **Provenance** — `Checkpoints.provenance/3` answers *which sessions touched this path* from
  `files_touched` alone (exact match, or a `path <> "/"` prefix so a directory matches
  everything below it), newest first, each match carrying the files that matched. This needed
  **no new index**: `files_touched` is already in every cached summary.
- **Surfaces** — all three reuse the same two functions, so GraphQL, MCP and the UI cannot
  disagree:
  - **LiveView** (Sessions tab): a GET search form (`?q=`), the labels under each matching row,
    a distinct "No recorded sessions match …" empty state, and pagination links that carry `q`.
    A public repository additionally renders a warning that its prompts and transcripts are
    cloneable (risk 1).
  - **GraphQL**: a `search_checkpoints(query:)` connection and a `checkpoint_provenance(path:)`
    connection on `object :repo`, both feeding the new `object :checkpoint_match`
    (`checkpoint`, `matched`, `score`, paginated through the same `slice_stream/2` +
    `Connection.from_slice/3` pattern as the other connections).
  - **MCP**: `checkpoint_provenance(owner, name, path, limit)` — `repo:read`, the catalog's 26th
    tool — and `search_checkpoints`, rewritten onto `Checkpoints.search/3`. Its
    `include_transcripts: true` still does the Phase 3 bounded scan (the 10 newest checkpoints,
    one session blob at a time, 64 KiB cap each) and merges the hits in, so a transcript result
    is strictly opt-in; `total_count` is now the true total, the `limit` only truncating the
    returned list.

Deliberately **not** done in Phase 4 (each is a small, independent follow-up):

- **Transcript search over the whole history.** Indexing transcripts would put megabytes of
  agent output into MetaDB (and need the new streaming NIF call to read a large `full.jsonl`
  without materialising it). The bounded, opt-in scan stays the answer until that NIF call
  exists — see risk 3.
- **The per-file diff on the provenance view** (`Checkpoints.file_diff/3`) and a provenance
  **chip on the code/history pages**. `provenance/3` is the hard part and is done; surfacing it
  per file/page is UI polish, and the equivalent queries are already reachable over GraphQL and
  MCP.
- **Embeddings / semantic search.** Everything here is lexical and local; no external service,
  no model, no new dependency (see §2).
- **Line ranges.** Provenance is per file, not per hunk — `files_touched` has no line
  information.

### Phase 5 — Retention, guards & short ids ✅ done

Chosen scope: all four sub-phases, the storage view on the Sessions tab, reject `refs/entire/*`
when checkpoints are disabled, **no** retention pruner, changes left uncommitted.

- **5A — Deletion tolerance (tests + docs only).** The Phase-1 watermark already heals every
  deletion: `entire clean` / `entire doctor` delete a checkpoint ref, the next read sees a
  watermark mismatch and rebuilds, and `GitRekt.GitRepo.push/2` drops the cache eagerly when a
  push command touches `refs/entire/*`. No code was needed — the `describe "retention"` block in
  `checkpoints_test.exs` now pins it: a deleted ref disappears from `list/2` and from the rebuilt
  index document, `get/2`/`session/4` report `:not_found`, a delete push clears the cache, and an
  unreadable checkpoint is skipped rather than fatal.
- **5B — Storage report.** `Checkpoints.storage/1` walks every checkpoint tree and sums the
  **deduplicated** blob sizes (a blob two checkpoints share counts once), bounded by
  `@max_storage_checkpoints` (500) and `@max_storage_objects` (200 000); when a cap is hit the
  byte count is a documented lower bound and `truncated?` is `true`. It renders as an
  **admin-only** *Checkpoint storage* panel on the Sessions tab — the count, `format_bytes/1`,
  the truncation note, and the `entire clean` / `git push --delete` hint. It is recomputed for a
  repository admin on every Sessions list render and, unlike the summary index, is not cached in
  `GitGud.MetaDB`; the walk caps above, not a cache, are what keep it cheap. Deliberately **not**
  built: a pruner, so gitfrank never deletes checkpoint refs itself.
- **5C — Push-side guard.** `:gitrekt` stays generic: `WireProtocol.valid_reference_name?/1`
  enforces Git's own ref-name rules, and `ReceivePack` gained a `reference_policy` callback
  (mirroring Phase 4's `hide_references` threading) called for every reference a push would
  **write** — deletes are always allowed — emitting `ng <ref> <reason>` in place of `ok <ref>`.
  `:gitgud` supplies `GitGud.Checkpoints.reference_policy/0`: while reading is disabled every
  `refs/entire/checkpoints/*` write is refused (`checkpoint-reading-disabled`); while it is
  enabled a checkpoint ref must keep the CLI's `<shard>/<id>` shape (a two-character shard and an
  id of at least 12 characters); and any other name under
  `refs/entire/` is refused (`invalid-checkpoint-reference`) — the whole `refs/entire/*` namespace
  belongs to the CLI. Both transports set it alongside `hide_references:`.
- **5D — Short ids.** `resolve_location/2` resolves an **unambiguous** case-insensitive prefix
  (at least `@min_id_prefix_length` = 4 characters) to the full checkpoint id, and otherwise
  reports `:not_found` (too short, or no match) or `:ambiguous` (more than one match). It backs
  `get/2`, `session/4`, `tasks/2` and `prompts/2` — and therefore the GraphQL `checkpoint(id:)`
  and the MCP `get_checkpoint`, whose callers map `:ambiguous` to their own error — so the short
  id the UI shows and an `Entire-Checkpoint:` trailer carries now works everywhere the full ULID
  does.

The optional **control plane** (§8 level B: `entire login --server`, `org`/`project`/`repo`,
`activity`/`search`/`trail`, `entire://` clones) remains **deferred**; the checkpoint-sync value
does not depend on it.

### Phase 6 — Transcript rendering ✅ done

The Phase 2 viewer rendered a transcript line as `type` + text — a shape only the test *fixture*
ever had. Against a real capture the transcript was unreadable, for two reasons, both found in the
§11 data (`kanle/hello`, checkpoint `01M571…`):

1. **The wrong blob was being read.** `session/4` preferred the agent-native `full.jsonl`, which for
   OpenCode is a *pretty-printed JSON document* (242 lines of JSON syntax), not JSON Lines — so
   splitting it by newline produced 242 meaningless fragments (`"info": {`, `"id": …`). The CLI's
   compacted `transcript.jsonl` *is* JSON Lines, and is **agent-normalised**.
2. **The renderer assumed the wrong shape.** It read `entry["type"]`/`entry["text"]`, whereas the
   real lines carry a `content:` **array of parts** — and a compact *user* part has no `type` at all:

   ```json
   {"v":1,"agent":"opencode","type":"user","ts":"…","content":[{"id":"prt-…","text":"…"}]}
   {"v":1,"type":"assistant","ts":"…","input_tokens":49,"output_tokens":36,
    "content":[{"type":"tool_use","name":"write","input":{…},
                "result":{"output":"…","status":"success"}}]}
   ```

   `display_text/1` therefore handed a *list* to `Jason.encode!/1` and dumped raw JSON into the
   element.

**Domain.** `Checkpoints.session/4` gained a `:source` option — `:full` (the default; the
agent-native file) or `:compact` (the CLI's normalised one) — each falling back to the other when
the preferred file is absent, with the file actually read returned as `:source`. The default is
unchanged, so the GraphQL/MCP callers and the Phase 1 tests are untouched; only the LiveView asks
for `:compact`. (`read_first_blob/3` now carries `{path, source}` pairs and returns what it read.)

**Renderer.** `GitGud.Web.CheckpointTranscript` (`apps/gitgud_web/lib/gitgud_web/checkpoint_transcript.ex`)
turns a raw line into `%{role:, at:, text:, tools:, thinking:, tokens:, raw:}`: a parsed `DateTime`
for `at`, markdown-ready `text`, and per tool call `%{name:, input:, output:, status:, error?:}`
(a nested map/list input or output is pretty-printed). It recognises the compact envelope, the
Claude Code line (parts under `message.content`), the OpenCode-native line (`info.role` + `parts`
with `state`), and passes anything else — including a pretty-printed fragment — through as `:raw`
rather than guessing. It is pure, and unit-tested with the real shapes in
`apps/gitgud_web/test/gitgud_web/checkpoint_transcript_test.exs`.

**UI.** The detail view parses the page's lines once in `assign_session` and renders message cards:
a colour-coded role tag, timestamp and token counts, markdown text (`markdown_safe/1`), and
`thinking` / tool calls inside `<details>` (name, a one-line input hint, the pretty-printed input,
the output, `is-danger` on an error result). A toolbar carries the session's `agent`/`model` tags
(from `<i>/metadata.json`), which transcript was read (*compacted* vs *raw*), and a **`?tools=0`
toggle** that drops the tool calls server-side and reports how many it hid. The styles are a new
`assets/css/components/checkpoint/_all.scss`, pulled in by `components/_all.scss` like `popover` —
previously there were none at all, which is why the view was a monospace run-on.

**Fixture & tests.** `CheckpointFactory` now writes both transcripts the way the CLI does — the
agent-native `0/full.jsonl` (one JSON object per line) and the normalised `0/transcript.jsonl` (150
messages: a prompt whose part carries no `type`, a `tool_use` call, a text reply, then filler) — and
exposes `full_transcript/0`, `compact_transcript/0`, `prompt/0`, `reply/0`, `tool/0` and
`transcript_lines/0`. `checkpoint_live_test.exs` asserts the rendered messages and the tool toggle,
and its transcript pagination now starts at message 4. Suites: `:gitgud` 220 tests, `:gitgud_web`
209, both green.

### Phase 7 — AiderDesk document transcripts ✅ done

A real capture from **AiderDesk** (`edmondfrank/entire-aiderdesk`, checkpoint `01M591SX…`)
exposed a shape Phase 6 did not cover. The CLI wrote **no compact transcript** (the session tree
is only `metadata.json`, `content_hash.txt`, `full.jsonl`, `prompt.txt`), so `:compact` fell back
to `:full` — and AiderDesk's `full.jsonl` is, like OpenCode's, a **pretty-printed JSON document**
rather than JSON Lines:

```json
{"version": 2, "contextMessages": [ … ], "contextFiles": [ … ]}
```

Each entry is a message: `role:"user"` with a string `content`; `role:"assistant"` whose `content`
is a list of `reasoning` / `text` / `tool-call` parts; and a separate `role:"tool"` entry per
result (`tool-result`, matched to its call by `toolCallId`). Timestamps are epoch **milliseconds**
and token use / model / cost live in a per-message `usageReport`.

Because the whole file decodes as one document, `CheckpointTranscript` had turned every one of its
740 lines into a separate `:raw` card. Two things change:

- **`transcript/1`** (new; `messages/1` now delegates to it) joins the lines and, if they decode
  as a single JSON document — `contextMessages`, `messages`, a bare message or a list of them —
  builds messages from its entries; otherwise it keeps the per-line behaviour. A transcript that
  decodes as *neither* and in which no line is even a JSON object (a document fragment, say one
  truncated past `:max_bytes`) renders as a **single** `:raw` block instead of one card per line.
- The **AiderDesk parts** are recognised: `reasoning` → thinking, `tool-call` → a tool call, and
  `tool-result` → the result, whose `output.value[].text` is joined. Epoch-ms timestamps and
  `usageReport` (`sentTokens`/`receivedTokens`, `model`, `messageCost`) are read alongside the
  compact envelope's ISO `ts` and `input_tokens`/`output_tokens`. Each tool result is then
  **folded into the call it answers** (`toolCallId`, or a Claude Code `tool_use_id`) and the
  standalone result message dropped, so a call renders once with its input *and* output — the
  message map gained `call_id`, `model` and `cost` for this.

**UI.** The detail view still paginates, but by **messages**, not raw lines (a document is only
decodable as a whole) — "Showing *n* of *m* messages" — and the message header gained a `model`
and `cost` chip; `session_meta/2` now treats the CLI's empty-string `"model": ""` as absent, and
the `:full` source is labelled *full agent transcript* rather than *raw*. `:tool` messages (an
unmatched result) get their own border/label colour in `checkpoint/_all.scss`.

A live run against the capture also caught a defect the AiderDesk shape made obvious: the
collapsed tool row's **hint** was the input's first line, and a pretty-printed input's first line
is just `{` — so every row read `mcp-hub---code_mode {` with a blank box. `tool_hint/1` now
decodes the input and summarises its most telling field (`code: …`, `filePath: …`, `initial_user_prompt: …`,
`items: …`), falling back to the collapsed text for a non-JSON input.

**Fixture & tests.** `CheckpointFactory.write!/2` takes `transcript: :aiderdesk`, which writes the
document shape and no compact transcript (exposing `aiderdesk_transcript/0` and friends).
`checkpoint_transcript_test.exs` decodes a document, a separate-result fold and a fragment; a new
`checkpoint_live_test.exs` case asserts the whole capture renders as three messages with nothing
left raw. Verified against the real `~/Code/entire-aiderdesk` file (740 lines → 15 messages, 0
raw). Suites: `:gitgud` 225 tests, `:gitgud_web` 213, both green.

## 7. Risks and open questions

| # | Item | Notes / decision needed |
|---|---|---|
| 1 | **Transcript exposure** | Checkpoint data lives in the repo object store, so a **public** repo exposes prompts/transcripts to anyone who clones. This is Entire's own design; gitfrank should surface a warning in the UI/docs rather than silently hide refs. Confirm we advertise them for public repos. **Phase 2 status**: the Sessions tab follows repository visibility exactly (the same `RepoQuery.user_repo_query` gate the codebase uses), so on a public repo prompts/transcripts are readable anonymously. **Phase 4 status**: the tab now renders that warning explicitly — *"This repository is public, so the prompts and transcripts recorded in its checkpoints can be read by anyone who can clone it."* — above the search box whenever `repo.public`. The data is still not hidden (hiding refs would break the CLI's own clone/fetch), and §11 gotcha 5 records the same caveat for the operator. |
| 2 | **Advertisement policy** | Advertise all refs (default) vs. a flag. `reference_discovery` is on the hot path for every clone/fetch, and `large` transcript blobs are only fetched on demand, so advertising names is cheap — but it does reveal checkpoint *ids/count*. Prefer: advertise when `:checkpoints, enabled: true`. **✅ Resolved in Phase 4**: `:gitrekt` stays generic — `WireProtocol.reference_discovery/4` takes `hide_references: [prefix]`, threaded through a `hide_references` struct field on `UploadPack`/`ReceivePack` that `:gitgud` sets from `GitGud.Checkpoints.hidden_reference_prefixes/0` at both call sites (`GitGud.SSHServer` and `GitGud.SmartHTTPBackend`). With `enabled: false` the `refs/entire/checkpoints/` refs are now *omitted from advertisement* (they are still stored; the CLI can still push and fetch them by name), so a disabled instance no longer leaks their ids or count. Covered by `apps/gitgud/test/gitgud/checkpoints_transport_test.exs`. |
| 3 | **Size** | `full.jsonl` can be large. Stream from libgit2, cap in the index, never materialise into a LiveView or an MCP response unbounded. **Phase 3 status**: an MCP `get_checkpoint` returns a transcript only for an explicitly requested `session`, capped by `max_bytes`, and `search_checkpoints` reads transcripts only on request, for at most the 10 most recent checkpoints. A single `session/4` read still loads the whole blob before truncating — real streaming needs the new NIF call. **Phase 4 status**: the searchable index holds *prompts only* (each truncated to 4 KiB, terms capped per prompt and per term), so the common query path never touches a transcript at all; the opt-in transcript scan still reads at most 10 checkpoints and 64 KiB per blob. |
| 4 | **Per-ref permissions** | Push authorization is per-repository (`:push`), not per-ref, so a writer can write `refs/entire/*`. **✅ Phase 5**: authorization is unchanged (a writer still needs `:push`), and on top of it a push-side `reference_policy` refuses a malformed name under `refs/entire/*` and refuses the namespace entirely while checkpoints are disabled — the policy *shapes* what a writer may push, it grants nothing. Note it only guards names the transport writes, not the object store. |
| 5 | **Two backends** | Support `git-refs` first; add the `entire/checkpoints/v1` branch fallback so pre-existing repos work. |
| 6 | **ULID vs hex** | Parse both id shapes (26-char ULID and legacy 12-hex); use the id as an opaque string everywhere else. |
| 7 | ~~**MetaDB key shape**~~ | ✅ **Resolved** — one index document per repository, keyed `{:checkpoints, owner_login, name}`, guarded by a reference-name/target-oid watermark. Force-push, ref move and ref deletion all rebuild; covered by tests. See §6 Phase 1. |
| 8 | ~~**SSH transport broken for clone/fetch**~~ | ✅ **Fixed** — SSH `git clone`/`git fetch` used to fail with `fatal: remote transport reported error` for *every* repo, because the exit status was never sent on the `{:halt, …}` path. Not checkpoint-specific, but it is the transport the `entire` pre-push hook uses and the clone URL the UI shows. See §12. |

## 8. Compatibility contract (what "works with the entire CLI" means)

**Level A — checkpoint sync (target for this plan).** Works with plain git once Phase 0
lands:

```bash
# gitfrank is the origin, or
entire enable --checkpoint-push-remote gitfrank
# or a dedicated store
entire enable --checkpoint-remote <name>:<owner>/<repo>
```

`--checkpoint-remote` is **github/gitlab only** in 0.11.5 — it guards against a non-Entire host —
so gitfrank can only ever be the *push* remote (`--checkpoint-push-remote`, or the sole remote
after `entire enable`). That is all Level A needs: the checkpoint data travels as ordinary
references over `git push`, and the CLI's pre-push hook is what uploads it.

gitfrank then receives `refs/entire/checkpoints/<shard>/<id>` (create / fast-forward
update / delete), advertises them on `info/refs`, and serves them on fetch. No login, no
API, no tokens beyond the git remote's own credentials.

**Level B — control plane (deferred to Phase 5+ / separate design).** `entire login
--server`, `org`/`project`/`repo`, `activity`/`search`/`trail`, and `entire://` clones
require implementing an identity issuer plus (part of) the control-plane OpenAPI and the
`/.well-known` trust documents. Worth doing only if we want gitfrank to *replace*
entire.io for CLI operations; the checkpoint-sync value does not depend on it.

## 9. Verification

- **Unit/regression** (`:gitrekt` / `:gitgud`): ref-name classification and discovery with
  foreign refs — `apps/gitgud/test/gitgud/git_reference_test.exs`.
- **Phase 1 domain tests** (`apps/gitgud/test/gitgud/checkpoints_test.exs`, 58 tests — 29
  Phase 1, 15 Phase 4, 14 Phase 5):
  summaries, `get/2`, `session/4` (prompt, transcript, truncation), `tasks/2`, `prompts/2`
  (order, a session with no prompt, an unknown id), trailer and
  merge-commit linkage, the legacy branch, `checkpoint_ids/1`, and the index (write, hit,
  `invalidate/1`, watermark-driven rebuild, push invalidation, skipping an unreadable
  checkpoint). The fixture is built in memory with `GitAgent.odb_write` + `index_add` +
  `index_write_tree` + `commit_create` + `reference_create` — no network, no checked-in
  binaries.
- **Phase 2 UI tests** (`apps/gitgud_web/test/gitgud_web/live/checkpoint_live_test.exs`, 13
  tests — 7 Phase 2, 4 Phase 4, 2 Phase 5): the empty state, a list row (short id, linked commit,
  token usage), the detail (prompt,
  transcript, files touched, task, and the diff against the linked commit), transcript pagination
  (`?page=2` shows lines 101–150), the commit-history provenance chip, the redirect away from
  an unknown id, the public-repository warning, and the three search states (`?q=greeting` →
  row + `session 0 prompt` label + the query kept in the box and a **Clear** link; `?q=readme`
  → both the `files_touched` and the prompt label; `?q=nonexistent` → the "No recorded sessions
  match" state and no row). The fixture — now the shared `GitGud.Web.CheckpointFactory`, also used by the
  Phase 3 tests — writes the checkpoint tree in memory exactly like the domain test: no network,
  no binaries. (The `CommitDiffLive` chip is the same mechanism but is **not** covered:
  that page's `if connected?(@socket)` components make `Phoenix.LiveViewTest` patch the DOM, which
  calls `Floki.get_by_id/2` — removed in the pinned `floki 0.33.1` while `phoenix_live_view 0.20.12`
  still calls it — so a `live/2` mount of that page raises inside the test harness, not in the app.)
- **Phase 3 API tests**:
  `apps/gitgud_web/test/gitgud/graphql/checkpoint_test.exs` (8 tests — 4 Phase 3, 4 Phase 4) runs real documents through
  `GitGud.GraphQL.Schema.run/2` — the repo `checkpoints` connection (including the `url`, the
  `REF` source and the token usage), `checkpoint(id:)` with its raw `metadata.json`, the commit
  `checkpoints` connection via `revision(spec:)`, and the error for an unknown id — so it also
  exercises `RepoMiddleware`; `reference`-only URL resolution is unit-tested in
  `.../graphql/resolvers_test.exs`. `apps/gitgud_web/test/gitgud/mcp/checkpoint_tools_test.exs`
  (18 tests — 12 Phase 3, 6 Phase 4) covers the tools: the list (summary fields, `offset`, an empty repository, a
  private repository of another user as `not_found`), `get_checkpoint` (metadata, tasks, one
  session's prompt/transcript, an unknown id and an unknown session index),
  `search_checkpoints` (a prompt hit, a touched-file/branch/strategy hit, transcripts only when
  asked, and an empty query), and `checkpoint_provenance` (an exact file, a directory prefix, no
  match, an empty path, and a private repository of another user as `not_found`).
  `.../mcp/{server,personal_access_token_auth_test}.exs` assert the
  new catalog size (26).
- **Phase 4 search/provenance tests** —
  `apps/gitgud/test/gitgud/checkpoints_transport_test.exs` (15 tests — 7 Phase 4, 8 Phase 5) pins the advertisement gate
  end to end: `hidden_reference_prefixes/0` with checkpoints on and off (toggled with
  `Application.put_env` + `on_exit`), `WireProtocol.reference_discovery/4` advertising and
  omitting a checkpoint ref, the `hide_references` field threading through **both**
  `UploadPack` and `ReceivePack`, and Smart HTTP `info/refs` with and without the ref; and the
  `describe "search/3"` / `"provenance/3"` blocks in `checkpoints_test.exs` above cover
  tokenisation, the hard-`AND` across terms, field/prompt labelling, scoring and ordering, the
  terms in the index document, provenance by file and by directory, and an empty path. The
  LiveView and GraphQL/MCP search states are covered by the two bullets above. `MIX_ENV=test mix
  test` is green across both apps: `:gitgud` **225 tests, 0 failures, 12 skipped**; `:gitgud_web`
  **209 tests, 0 failures, 4 skipped**. (The Phase 6 transcript tests and the two §13 tests the
  live run added are counted here; §13 lists them.)
- **Phase 5 hardening tests** — `checkpoints_test.exs` gained `describe "retention"` (4 tests:
  a deleted ref leaves `list/2` and the rebuilt index document, `get/2`/`session/4` report
  `:not_found`, a delete push clears the cache, and an unreadable checkpoint is skipped),
  `describe "short id resolution"` (5 tests: an unambiguous prefix, a lowercase prefix, a full
  id, an ambiguous prefix, and a prefix below the minimum) and three `storage/1` blocks (5 tests:
  the byte count, a blob two checkpoints share counted once, and the disabled / legacy-branch
  cases). `checkpoints_transport_test.exs` added `describe "reference_policy/0"` (3 tests) and
  `describe "the push guard"` (5 tests: a malformed checkpoint ref is reported `ng`, a
  Git-forbidden name too, an ordinary ref is still `ok`, the namespace is refused while
  checkpoints are disabled, and a delete is always allowed). `git_reference_test.exs` covers
  `WireProtocol.valid_reference_name?/1`, and `checkpoint_live_test.exs` (2 tests) covers the
  storage panel: shown to a repository admin, absent for an anonymous viewer.
- **SSH transport regression** (`apps/gitgud/test/gitgud/ssh_server_test.exs`, "clones and
  fetches over SSH"): pushes a commit over SSH, then clones and fetches it, asserting the `ssh`
  exit status is 0 — the §12 bug fails this.
- **End-to-end** (manual, documented): run `entire enable` against a local gitfrank, make a
  commit with an agent, confirm the ref arrives, the UI lists it, and GraphQL/MCP return it.
  The **git-side half of this is done** — capture, trailer, checkpoint ref, upload, and
  re-advertisement were all exercised against the dev server; the reproducible runbook and
  observed output are in §11. The UI half is covered by the Phase 2 tests and the API half by the
  Phase 3 tests above — an agent can now also *query* why, over GraphQL or MCP.
- Run `MIX_ENV=test mix test` (remember `MIX_ENV` — see `AGENTS.md` §5) before any PR.

## 10. Milestone summary

| Phase | Scope | Deliverable |
|---|---|---|
| 0 | Fix ref classification + tests ✅ | gitfrank safely hosts `refs/entire/*` |
| 1 | `GitGud.Checkpoints` + MetaDB index ✅ | Checkpoints readable server-side |
| 2 | Sessions tab + checkpoint detail + commit chips ✅ | Humans can see *why* |
| 3 | GraphQL + MCP tools ✅ | Agents can query *why* |
| 4 | Search + provenance ✅ | Agents stop re-deriving work |
| 5 | Retention tolerance, storage report, push guard, short ids ✅ | Hardening (control plane still deferred) |
| 6 | Transcript viewer: message cards, tool calls, `?tools=0` ✅ | The capture is *readable* |
| — | Post-validation fixes: delete-only push, checkpoint→commit link, deprecations ✅ (§13) | Delete and link work on a real capture |

Phases 0–4 are done, and the git side was validated against a real `entire`-enabled repository
(§11). Phase 4 (search & provenance) built on them, replacing the bounded, prompt-only scan in
`search_checkpoints` with a real prompt index in `GitGud.MetaDB` shared by the Sessions tab, the
GraphQL `repo.search_checkpoints`/`repo.checkpoint_provenance` connections and the MCP
`search_checkpoints`/`checkpoint_provenance` tools — so *"which session changed this file, and
why"* is now one query, answered from the index, with no transcript read. Phase 5 then closed the
retention and guard work — deletions heal the index on their own, an admin-only storage report
sits on the Sessions tab, the push side enforces the `refs/entire/*` namespace, and an
unambiguous short id resolves everywhere. What is left is only the optional control plane in
§8 level B, plus the two small Phase 4 follow-ups listed at the end of §6.

---

## 11. Validated runbook — Entire CLI ↔ gitfrank

Executed against the dev server (HTTP `:4000`, SSH `:9989`) with **Entire CLI 0.11.5**. This
is the phase-0 acceptance test: it exercises capture → trailer → checkpoint ref → upload →
re-advertisement as one loop.

### 11.1 Install (macOS)

```bash
brew tap entireio/tap
brew install --cask entireio/tap/entire   # Homebrew 7+ requires the explicit tap/trust first
entire --version                          # Entire CLI 0.11.5
```

The cask installs both `entire` and `git-remote-entire`. Alternatives: `curl -fsSL
https://entire.io/install.sh | bash` (→ `~/.local/bin`) and Scoop on Windows. `go install`
needs Go ≥ 1.27.1.

### 11.2 Enable

```bash
git clone http://localhost:4000/<owner>/<repo>.git work && cd work
entire enable --agent opencode --yes --telemetry=false
```

`entire enable` is **purely local**: no `entire login`, no API call. It writes:

| Artifact | Content |
|---|---|
| `.entire/settings.json` | `{"enabled":true,"telemetry":false,"checkpoints":{"primary":{"type":"git-refs"}}}` |
| `.entire/.gitignore` | `tmp/`, `settings.local.json`, `metadata/`, `logs/`, `redactors/local/` |
| `.git/hooks/{prepare-commit-msg,commit-msg,post-commit,post-rewrite,pre-push}` | thin `entire hooks git <hook>` shims; `pre-push` forwards `$1` (the remote name) |
| agent plugin | e.g. `.opencode/plugins/entire.ts`, or 10 hook entries in `.claude/settings.json` |

> **Prerequisite — a Git identity.** "Purely local" is only true once the repository has one:
> with none configured, `entire enable` stops with *"Git identity is missing, and Entire
> authentication is required"*. A repository-local identity
> (`git config user.name … && git config user.email …`) is enough — still no login and no API call.

`entire status` then reports `Checkpoints sync to: origin` — the election picked the sole
remote, so the `pre-push` hook will upload checkpoint refs there.

### 11.3 Capture → commit → push

```bash
<agent> "…"                        # any agent Entire supports
git add -A && git commit -m "…"     # commit-msg hook adds the trailer
git push origin main                # pre-push hook also uploads the checkpoint refs
```

Observed:

```
prepare-commit-msg: agent commit trailer added   checkpoint_id=01M571KGMD0S50TGCKDARSTWSZ
[entire] Pushing 1 checkpoint ref(s) to origin... done
   1907bb2..4cc5502  main -> main
```

The local ref matches §3.2 exactly (`SZ` = last two characters of the ULID):

```
refs/entire/checkpoints/SZ/01M571KGMD0S50TGCKDARSTWSZ  →  fed4bfc
```

### 11.4 Server-side assertions (all pass)

| Check | Result |
|---|---|
| `git ls-remote 'refs/entire/*'` over SSH **and** HTTP | `fed4bfc… refs/entire/checkpoints/SZ/01M571…` |
| `GET …/info/refs?service=git-upload-pack` | **200**, body contains `refs/entire/checkpoints` — the phase-0 assertion; this used to raise `FunctionClauseError` |
| `…?service=git-receive-pack` unauthenticated | 401 (correct) |
| Fresh clone of the repo | succeeds, working tree intact |
| On-disk ref | `priv/git-data/<owner>/<repo>/refs/entire/checkpoints/SZ/01M571…` |
| Checkpoint tree | root `metadata.json` + `0/{metadata.json,full.jsonl,transcript.jsonl,prompt.txt,content_hash.txt}` — matches §3.2 |

The stored `metadata.json` (abridged) also carries `token_usage`, which Phase 1's index can
surface directly:

```json
{"cli_version":"0.11.5","checkpoint_id":"01M571KGMD0S50TGCKDARSTWSZ","strategy":"manual-commit",
 "branch":"main","checkpoints_count":1,"files_touched":["SECOND.md"],
 "sessions":[{"metadata":"/0/metadata.json","transcript":"/0/full.jsonl",
              "compact_transcript":"/0/transcript.jsonl","content_hash":"/0/content_hash.txt",
              "prompt":"/0/prompt.txt"}],
 "token_usage":{"input_tokens":158,"cache_read_tokens":40192,"output_tokens":54,"api_call_count":2}}
```

### 11.5 Operational gotchas (these cost real time)

1. **One agent per repository.** Enabling two agents (`entire enable --agent claude-code`
   and then `entire agent add opencode`) makes the session resolve to the *first* agent's
   ownership; the second agent's hook calls are dropped —
   `skipping forwarded hook for non-owning agent … owning_agent: Claude Code, firing_agent:
   OpenCode` — the transcript stays empty, condensation fails (`condensation failed: failed
   to extract session data from live transcript: live transcript is empty or unreadable`)
   and **no checkpoint is created**. The commit *still* gets an `Entire-Checkpoint:` trailer,
   so it looks like it worked. Fix with `entire agent remove <name>`. Diagnostics live in
   `.entire/logs/entire.log` (JSON lines).
2. **`opencode run` needs a TTY.** Non-interactive `opencode run "…"` exits 0 doing nothing;
   under a pty (`script -q /dev/null opencode run "…"`) it works normally.
3. **Use an agent that actually records transcripts.** `claude -p` produced no session here
   (`~/.claude/projects` absent), so `entire` had nothing to condense. Verify with
   `entire session list` before expecting a checkpoint.
4. **The SSH clone URL uses the login, not `git`** —
   `ssh://<login>@<host>:<port>/<owner>/<repo>.git` (see `tree_browser_live.html.heex`).
   `ssh://git@…` authenticates as a user literally named `git`, which `is_auth_key/3` resolves
   through `UserQuery.by_login/1` and therefore rejects.
5. Because checkpoint refs live in the object store, a **public** repo exposes prompts and
   transcripts to anyone who clones (risk 1 in §7). Nothing was changed here; it is Entire's
   own model.
6. **A delete-only push leaves the client hanging.** `entire checkpoint delete <id> --remote
   origin` printed `Local ref: deleted / origin: ref failed / git push: signal: killed` and the
   ref stayed on the server; plain `git push origin :branch` hung for *any* user. The cause and
   the fix are in §13.1.
7. **The CLI records no `commit_sha`.** `metadata.json` has none, so the only link between a
   checkpoint and the commit it came from is the `Entire-Checkpoint:` trailer in that commit —
   which is why the detail page used to say *"not linked to a commit"*. Resolved server-side in
   §13.2.
8. **On the legacy branch backend the checkpoints are a *branch*,** `entire/checkpoints/v1`,
   sharded `<shard>/<rest>/`. It is pushed, advertised and fetched like any other branch, and
   `entire status` reports a checkpoint as *"1 checkpoint not yet on origin"* until it has been.

## 12. Fixed: SSH `git clone` / `git fetch` failed with `remote transport reported error`

Found while validating §11. Pre-existing and **not** checkpoint-specific — it reproduced with
every repository on the server, while HTTP was unaffected. **Fixed** in
`apps/gitgud/lib/gitgud/ssh_server.ex`. Symptom: the pack transferred completely, then the
transport aborted.

```
Receiving objects: 100% (21/21), 4.89 KiB | 4.89 MiB/s, done.
Resolving deltas: 100% (1/1), done.
fatal: remote transport reported error
```

`GIT_TRACE_PACKET` shows the exchange is otherwise healthy — v0 advertisement, `want` ×2,
`0000`, `done`, `NAK`, then a valid 21-object pack — so the protocol state machine is fine.
The failure is the **SSH session exit status**:

| Command | `ssh` exit status |
|---|---|
| `git ls-remote ssh://…` | 0 |
| `git clone ssh://…` (upload-pack) | **255** |
| `git push ssh://…` (receive-pack) | 0 |

git treats a non-zero transport status as a failure ⇒ *"remote transport reported error"*.

### Root cause

`GitGud.SSHServer` (`apps/gitgud/lib/gitgud/ssh_server.ex`) reports the exit status **only**
in its EOF handler:

```elixir
def handle_ssh_msg({:ssh_cm, conn, {:eof, chan}}, %__MODULE__{conn: conn, chan: chan} = state) do
  :ssh_connection.exit_status(conn, chan, 0)
  :ssh_connection.close(conn, chan)
  {:ok, state}
end
```

But the two paths differ, because the `{:halt, …}` branch already sends EOF itself:

```elixir
{:halt, service, output} ->
  :ssh_connection.send(conn, chan, output)
  :ssh_connection.send_eof(conn, chan)          # ← no exit_status here
  {:ok, %{state|service: service, request_size: request_size + byte_size(data)}}
```

- `ls-remote` / `push`: the **client** finishes first and sends EOF ⇒ the `{:eof, chan}`
  handler runs ⇒ exit status `0`. ✅
- `clone` / `fetch`: the **server** halts and sends EOF first, then the client closes the
  channel. The server sees `{:closed, chan}`, which falls through to the catch-all
  `handle_ssh_msg({:ssh_cm, conn, _msg}, %__MODULE__{conn: conn} = state) -> {:ok, state}`,
  so **`exit_status` is never sent** ⇒ OpenSSH reports 255. ❌

### Fix (applied)

Report the status on the halt path, before the peer can close — but *once only*, because a push
still sends EOF and would otherwise be reported from both clauses:

```elixir
defstruct [:conn, :chan, :user, :repo, :service, request_size: 0, exit_status_sent: false]
…
{:halt, service, output} ->
  :ssh_connection.send(conn, chan, output)
  :ssh_connection.exit_status(conn, chan, 0)
  :ssh_connection.send_eof(conn, chan)
  {:ok, %{state|service: service, exit_status_sent: true, request_size: request_size + byte_size(data)}}
…
def handle_ssh_msg({:ssh_cm, conn, {:eof, chan}}, %__MODULE__{conn: conn, chan: chan} = state) do
  if !state.exit_status_sent, do: :ssh_connection.exit_status(conn, chan, 0)
  :ssh_connection.close(conn, chan)
  {:ok, state}
end
```

Plus an explicit `{:closed, chan}` clause, so the `{:eof, chan}` / `{:closed, chan}` split that
caused this is visible at the site instead of hidden in a catch-all.

The once-only guard is not cosmetic: without it, a push reports the status from *both* clauses,
OpenSSH logs `mux_client_request_session: exitval sent twice`, and git prints
`error: failed to push some refs` **even though the ref was updated** — a false failure that the
original bug had masked (it is what the first version of this fix introduced).

### Verified

| Command | Before | After |
|---|---|---|
| `git ls-remote ssh://…` | works | works |
| `git clone ssh://…` | `ssh` exit 255 → *remote transport reported error* | **exit 0, clone succeeds** |
| `git fetch ssh://…` | exited 0 but fetched nothing | fetches refs |
| `git push ssh://…` | worked | works, no spurious `failed to push some refs` |

Checked against the live dev server (`:9989`) using a `GIT_SSH_COMMAND` shim that records the
`ssh` exit status, on `kanle/hello`, `kanle/appswitcher` and `kanle/imeswitch`. The full suite
still passes (`:gitgud` 144 tests / 12 skipped, `:gitgud_web` 157 tests / 4 skipped).

Two caveats: the SSH listener starts at boot, so a running server only picks the fix up once it
recompiles the module (a `mix phx.server` code reload is enough) or restarts; and **no automated
regression test covers this yet** — the halt path cannot be exercised without a real SSH channel,
so it needs an `:ssh.daemon`-based integration test.

### Why it mattered here

SSH is how the `entire` pre-push hook uploads checkpoint refs, and it is the clone URL the UI
recommends — so a repo hosting checkpoints could be **pushed to but not cloned** over SSH. That
is why §11's validation was run with an HTTP clone plus an SSH push URL; with this fix, plain
SSH clone and push both work end-to-end.
---

## 13. Post-validation fixes (found by the §11 live run)

Two defects only a real `entire` 0.11.5 session exposes, plus a deprecation. Fixed; `MIX_ENV=test
mix test` is green across both apps — `:gitgud` **225 tests, 0 failures, 12 skipped**;
`:gitgud_web` **209 tests, 0 failures, 4 skipped**.

### 13.1 A delete-only push hung — every `git push --delete`

`git send-pack` sets `need_pack_data = 0` when *every* command in the push is a deletion (a
deletion needs no objects) and closes the stream right after the command list, so a delete-only
push carries **no packfile at all**. `GitRekt.WireProtocol.ReceivePack` moved to `:pack` after
parsing the commands and waited there for pack data that never comes: `:done` was never reached,
`unpack`/`report-status` were never sent, and the two sides deadlocked. The server log shows it
exactly — the step after the command list never runs:

```
[debug] (gitrekt) receive_pack start  update_req
[debug] (gitrekt) executed update_req in 236 µs     # then nothing: no :pack, no :done
```

Impact was not checkpoint-specific: `entire checkpoint delete <id> --remote origin` reported
`Local ref: deleted / origin: ref failed / git push: signal: killed` and left the reference on the
server, and plain `git push origin :branch` hung for every user. Git's own `receive-pack` has a
`delete_only()` short-circuit for this; gitfrank's did not.

**Fix.** `ReceivePack.next/2` now goes straight to `:done` when the parsed commands are all
deletions *and* nothing is left to read, mirroring git; a client that sends a pack anyway still has
it consumed (`progress.received_bytes == 0` already made `push_pack/3` a no-op for a delete). This
covers both transports, since `GitGud.SSHServer` and `GitGud.SmartHTTPBackend` both drive
`GitRekt.WireProtocol`.

**Verified live** over SSH (`git push ssh://… :refs/heads/verify-delete-fix`): `- [deleted]
verify-delete-fix` in ~0.1 s, where it previously never returned.

```
== F2 (fixed node :9997): delete-only push
   $ git push ssh://kanle@localhost:9997/kanle/appswitcher.git :refs/heads/verify-delete-fix
   -> exit=0 in 0.1s
      - [deleted]         verify-delete-fix
```

Covered by `describe "a delete-only push"` in
`apps/gitgud/test/gitgud/checkpoints_transport_test.exs` (2 tests): one drives the service from
`:update_req` with a deletion command and a flush — no pack — and asserts a single
`WireProtocol.next/2` call reaches `:done`, emits `unpack ok` / `ok <ref>` and deletes the ref; the
other does the same from a fresh service through the advertisement.

### 13.2 No checkpoint→commit link — `metadata.json` has no `commit_sha`

CLI 0.11.5 writes no `commit_sha` into `metadata.json`, and the checkpoint commit is a *root*
commit, so no parent link exists either. The only link is the `Entire-Checkpoint: <id>` trailer
the CLI writes into the user's **own** commit. `GitGud.Checkpoints` read
`metadata["commit_sha"]`, so every real checkpoint fell back to *"This checkpoint is not linked to
a commit."* — no *Changes* diff, and `commitSha: null` over GraphQL and MCP. The web tests did not
catch it because `CheckpointFactory` *invented* a `commit_sha` in the metadata it wrote.

**Fix.** `GitGud.Checkpoints` resolves the link from the trailer:

* it groups the checkpoints by the `branch` each records (falling back to `repo.default_branch`),
  walks that branch newest-first (`sort: :sort_time`) bounded by `@max_link_commits` (100) and
  reads the `Entire-Checkpoint:` trailers off the commit messages, building `id => commit sha`;
* the result is cached in `GitGud.MetaDB` under `{:checkpoints_links, owner_login, name, branch}`
  **keyed by the branch tip oid** — so the push that delivers the trailer invalidates it, while a
  push of a checkpoint reference alone does not throw it away;
* metadata still wins when it does carry a `commit_sha` (a future CLI needs no change here), and
  the whole thing is best-effort: a deleted branch, an unreadable commit or a repository that
  never received the trailer just leaves the checkpoint unlinked;
* a new `checkpoint_ids/1`-style link is case-insensitive, like `resolve_location/2` — a ULID is
  uppercase base32, a legacy id is lowercase hex, and the trailer carries whichever the CLI holds.

`list/2`, `get/2` and `for_commit/2` all carry the resolved sha, so the Sessions tab, the
commit-history code (which indexes checkpoints by the commit sha the CLI put in the trailer), the
GraphQL `commitSha` and the MCP `commit_sha` all agree. `CheckpointLive` now takes its diff sha
from the summary's `commit_sha` rather than `metadata["commit_sha"]`, and `CheckpointFactory` no
longer writes one — so the LiveView/GraphQL/MCP tests exercise the resolution instead of asserting
the fixture's invention.

**Verified against the real repository** (`kanle/appswitcher`, captured by CLI 0.11.5):

```
[verify] F1 links for kanle/appswitcher:
  id=01M57WC2AEC6GYMY1WPHX6SMTT source=ref branch="main" commit_sha="925f417e795588832c5baaf75bf6076a57d9dbff"
```

`925f417` is the commit whose message carries `Entire-Checkpoint: 01M57WC2AEC6GYMY1WPHX6SMTT` (the
same `HEAD` the §11 run pushed); before the fix the same call returned `nil`. The debug log shows
the walk is two commits deep: `history(<GitCommit:925f417>, [sort: :sort_time])` →
`commit_message` ×2.

Covered by `checkpoints_test.exs`: three new `list/2` tests (the link from `list/2` **and**
`get/2`; the trailer index cached under the branch tip with the id case-folded; a checkpoint whose
branch carries no trailer left unlinked) and one more assertion on `for_commit/2`.

### 13.3 Elixir 1.18 negative-step deprecations

`GitGud.SSHServer.parse_args/1` dropped the `.git` suffix with `String.slice(repo_name, 0..-5)`,
which Elixir 1.18 warns about on every command parsed (*"negative steps are not supported in
`String.slice/2`"*); it now uses `String.trim_trailing/2`. The same deprecated form in
`GitGud.ContentStore.transform_key/1` (`4..-1`) and `GitGud.Web.Markdown`
(`1..-2`, the emoji shortcode) is now written as the explicit step the warning asks for
(`4..-1//1`, `1..-2//1`), which behaves identically.
