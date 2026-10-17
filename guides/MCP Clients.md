# Connecting MCP Clients to gitfrank

gitfrank speaks the **Model Context Protocol** over **Streamable HTTP** at a
single endpoint:

```
POST https://<your-gitfrank-host>/api/mcp
```

Protocol version: `2025-06-18` (sent as the `MCP-Protocol-Version` header).
Design, tool catalog and the scope model live in `guides/MCP.md`.

---

## 1. Create a personal access token

MCP clients authenticate with a **personal access token** (PAT); a 24h
`Phoenix.Token` is also accepted but is meant for programmatic/browser use.

1. Sign in and open **Settings → Personal access tokens**
   (`/settings/tokens`).
2. **New access token**, give it a name (e.g. `AiderDesk on laptop`), tick the
   scopes you need and optionally an expiry.
3. Copy the token — it is shown **exactly once**. It looks like
   `gf_<base32>`.

Prefer one token per client so you can revoke it independently.

### Which scopes do I need?

| Scope | Grants |
|---|---|
| `user:read` | `whoami`, and user results in `search` |
| `repo:read` | repository metadata, branches/tags, trees, file contents, commits, releases, and repository results in `search` |
| `repo:write` | reserved for future repository mutations |
| `issue:read` | list/get issues, issue comments |
| `issue:write` | create/comment/close/reopen/retitle/label issues, edit/delete comments |
| `review:write` | commit line review comments |

A token that lacks a tool's scope simply does not see it in `tools/list`, and
gets a JSON-RPC error with `data.required` naming the missing scope if it calls
it anyway. `search` spans users *and* repositories, so it needs **both**
`user:read` and `repo:read`. Session/bearer credentials (the browser) are
unrestricted.

Suggested presets:

- **Read-only browsing**: `user:read`, `repo:read`, `issue:read`
- **Issue triage / automation**: the above + `issue:write`
- **Code review**: the above + `review:write`

---

## 2. Smoke test with `curl`

MCP over Streamable HTTP is a JSON-RPC 2.0 handshake followed by requests. First
`initialize` (note the `Mcp-Session-Id` response header), then notify, then call.

```bash
TOKEN="gf_…"
URL="https://gitfrank.example.com/api/mcp"
HDRS=(-H "Authorization: Bearer $TOKEN"
      -H "Content-Type: application/json"
      -H "Accept: application/json"
      -H "MCP-Protocol-Version: 2025-06-18")

curl -sS -D /tmp/mcp.headers "${HDRS[@]}" "$URL" -d '{
  "jsonrpc": "2.0", "id": 1, "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "curl", "version": "0"}
  }
}'

SESSION=$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' /tmp/mcp.headers | tr -d '\r')

curl -sS "${HDRS[@]}" -H "Mcp-Session-Id: $SESSION" "$URL" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Discover the tools this token may use:
curl -sS "${HDRS[@]}" -H "Mcp-Session-Id: $SESSION" "$URL" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Call one:
curl -sS "${HDRS[@]}" -H "Mcp-Session-Id: $SESSION" "$URL" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
       "params":{"name":"whoami","arguments":{}}}'
```

Tool results are JSON envelopes: `{"ok": true, "data": …}` or
`{"ok": false, "error": "…", "detail": …}`.

Instead of `Authorization: Bearer`, you may send the token in `X-Api-Key: gf_…`.

---

## 3. AiderDesk

`~/.aider-desk/mcp-servers.json`:

```json
{
  "mcpServers": {
    "gitfrank": {
      "url": "https://gitfrank.example.com/api/mcp",
      "headers": { "Authorization": "Bearer gf_…" }
    }
  }
}
```

---

## 4. Claude Code

CLI:

```bash
claude mcp add --transport http gitfrank https://gitfrank.example.com/api/mcp \
  --header "Authorization: Bearer gf_…"
```

or a settings file (`~/.claude.json`, project `.mcp.json`):

```json
{
  "mcpServers": {
    "gitfrank": {
      "type": "http",
      "url": "https://gitfrank.example.com/api/mcp",
      "headers": { "Authorization": "Bearer gf_…" }
    }
  }
}
```

---

## 5. Zed

```json
{
  "context_servers": {
    "gitfrank": {
      "source": "custom",
      "command": {
        "path": "npx",
        "args": [
          "-y", "mcp-remote", "https://gitfrank.example.com/api/mcp",
          "--header", "Authorization: Bearer gf_…"
        ]
      }
    }
  }
}
```

Zed's native Streamable HTTP support is still evolving; the
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) bridge works on every
build and also handles the session handshake.

---

## 6. Any other client

Anything that speaks Streamable HTTP can connect:

- **URL**: `https://<host>/api/mcp`
- **Headers**: `Authorization: Bearer gf_…` (or `X-Api-Key: gf_…`),
  `Content-Type: application/json`, `Accept: application/json`,
  `MCP-Protocol-Version: 2025-06-18`
- **Server info**: `gitfrank` (capability: `tools`)

Two optional request headers let a client trim the exposed toolset:

- `x-include-tools: get_repository,read_file` — only expose these tools.
- `x-exclude-tools: create_issue` — hide these tools (applied after include).

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `401 Unauthorized` (JSON-RPC `-32001`) | Missing/invalid/revoked/expired token, or wrong prefix. Mint a new one. |
| A tool is missing from `tools/list` | The token lacks that tool's scope — check §1 and `guides/MCP.md` §9. |
| `error.message == "insufficient_scope"` on `tools/call` | `data.required` names the scope to add. |
| `405`/`404` on the endpoint | MCP is disabled (`:gitgud_web, :mcp, :enabled`) or the path differs (`:mcp, :path`). |
| No `Mcp-Session-Id` response header | The `initialize` request was rejected — check the headers above. |

Server-side, each `tools/call` emits `[:gitgud, :mcp, :tool, :call, :stop]`
telemetry with `%{tool:, result: :ok | :error | :denied, user_id:, scopes:}`
(logged at `debug` by `GitGud.MCP.Telemetry.LoggerHandler`), which is the
quickest way to see why a call failed.