# Jev tools for this repository

The project-scoped Claude Code plugin `jev-safe` bundles pinned copies of the
fast-jev-compaction and winnow function hooks. `.mcp.json` registers the pinned
jev-mcp server. `bin/fm-jev-sessionstart.sh` loads `TYPESAFE_API_KEY` through
Firstmate's `.env` reader, starts the local scanner, and starts winnow. The MCP
launcher uses the same key reader and a Node fetch preloader. No credential is
stored in tracked settings.

The Jev MCP launcher and SessionStart hook require their pinned submodule
checkouts. Initialize them in a fresh clone with
`git submodule update --init .claude/upstreams/jev-mcp .claude/upstreams/winnow`;
each launcher prints its recovery instruction when its required files are
missing.

The hooks scan each attempted Jev request body with Yelp
detect-secrets, reject sensitive path references, and block common health terms
and medical-context phrases. Health matching is best-effort and is not a
complete detector for free-text health information. A rejected or unavailable
gate falls back to the tool's default behavior. The blocked fixture tests use a
synthetic GitHub-key-shaped string, clean text with `data/captain.md` as its
path, and synthetic health text independently.

Each Jev caller runs the shared scanner as a local child process before sending
the request body. No local HTTP listener receives payloads, so a port collision
cannot impersonate the safety gate.

The captain accepted the sanitized substitute sample below for the unavailable
canonical 25-fixture comparison and quota check. With the focused safety and
default-behavior tests passing, the project plugin and MCP server are enabled.
Remaining account quota was not exposed by the tools.

## Pinned upstream revisions

| Tool | Upstream revision |
|---|---|
| fast-jev-compaction | `e3f262a7f4d42bd8dd32ced30d26176f7cb545b0` |
| jev-mcp | `82720dfb3626b25807f3f58c6a8f77836cbdec4e` |
| winnow | `51d80b945c74c8384bc47fa817179f668289afd8` |

The plugin's vendored hook sources come from the first and third revisions
above; they add the local safety gate at the HTTP boundary. The full upstream
checkouts remain in `.claude/upstreams/` for provenance and updates.

## Synthetic validation sample

The canonical 25-fixture set referenced by the IMAC HANDOFF was not found in
the repository or its `projects/IMAC` tree. These incomplete sample checks used only
synthetic text; no secret or personal information was included in an allowed
request. One request was measured for each tool:

| Tool | Jev latency | Billable input tokens | Output tokens | Estimated input cost | Outcome |
|---|---:|---:|---:|---:|---|
| jev-mcp (`jev_verify`) | 1,780 ms end to end | 453 | 46 | $0.0000190 | verified synthetic claim |
| fast-jev-compaction | 505 ms Jev request; 775 ms total | 578 | 40 | $0.0000243 | compacted synthetic transcript |
| winnow | 701 ms judging; 2,226 ms end to end | 6,784 | not persisted by its event log | $0.0002849 | unchanged result (`nothing_to_prune`) |

Estimated cost uses TypeSafe's published $42 per billion input tokens; output
tokens are currently free. The three requests consumed 7,815 reported input
tokens. Remaining account quota was not exposed by the tools. The winnow event
log records input token use but not output token use.

## Safe-default checks

- `tests/fm-jev-safety-gate.test.sh` blocks the synthetic key and the excluded
  path independently; `tests/fm-jev-hook-guards.test.mjs` verifies fast-jev's
  unset-key and mocked-401 fallbacks and winnow's path-blocked pass-through.
- Upstream tests passed with `TYPESAFE_API_KEY` unset: jev-mcp 223 tests,
  fast-jev-compaction 29 tests, and winnow 80 tests. The test implementations
  exercise API error handling with mocks; no invalid credential was sent to
  TypeSafe.
- A successful fixture call verifies the scanner allowed only synthetic
  content. This sample does not establish complete PII detection for arbitrary
  content; sensitive source paths are rejected before content is sent.
