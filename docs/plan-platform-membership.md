# Pi, Claude Code and Codex support

Status: proposed implementation plan, not a claim that all three clients work.
The approved membership model is durable identity with expiring presence. The
broker foundation is implemented for review in PR #24; it is not deployed.

## Goal

One membership implementation, one inbox watcher, small client adapters.
Adding an agent requires an explicit team folder, label and client. There is no
roster, configured worker count, inferred team or automatic replacement ring.
The user starts the native client using a generated command.

Supported means tested on a recorded client version, not just an MCP connection
or a successful model response once. Tool approval and project approval gates
remain in effect. Never enable blanket permission bypass to make a smoke pass.

## What exists and what does not

- Pi has a host extension and watcher that request turns without empty model
  polling. It still needs the common membership/recovery and credential boundary.
- The Claude work in PR #20 prepares files and a native launch command. Its hooks
  detect expiry but leave recovery to the model. This is not reliable automatic
  support. The model reading credentials also caused a transcript exposure.
- Claude /loop can schedule inbox checks, but spends model turns on empty inboxes
  and has scheduler lifetime/resume limitations. It is an explicit compatibility
  mode, not equivalent to a host-side watcher.
- There is no completed Codex adapter.
- Live users have executed scripts from a mutable development checkout. Switching
  branches changed their CLI. Installation isolation is part of correctness.

## Keep the user interface small

Target entry point, extending the file-based flow in PR #20:

```sh
agent-talk add cc-w5 --team manual-4 --client claude
agent-talk add cx-w9 --team manual-4 --client codex
agent-talk add w-10 --team manual-4 --client pi
```

Each prepares one unused identity and prints a native client command. The
command's host integration must ensure membership is valid again at actual
startup, not assume allocation and launch happen at the same time.

Existing identities need an explicit resume/recovery operation, not another add.
Provide one `agent-talk resume LABEL --team NAME` operation that repairs the saved
membership and prints that same client's launch command. Do not overwrite a live
identity. Keep status under `agent-talk status LABEL --team NAME`. Use these
operations for all clients, not a separate repair command per platform.

Ring creation is a separate explicit PM operation. An empty folder is not
permission to create a ring. Keep legacy init/start temporarily for compatibility;
remove the roster-based interface after existing users migrate, rather than
maintain two onboarding systems indefinitely.

## Files and identity

Use the existing `.agent-talk/<team>/` directory:

- `invitation.json`: private ring invitation and authoritative public PM/ring IDs.
- `<label>.json`: complete private registration, written atomically, mode 0600.
- Per-agent native connection/binding files as required by the client, containing
  no bearer credentials. Include schema version, client, server URL, expected
  ring, logical label and membership path. No project-wide roster or registry.
- A short-lived operation lock and a live-session ownership lock where required.
  These are runtime artifacts, not another configuration system.

The stable local identity is the explicit server, ring and logical label. A
server node_id identifies a durable registration until explicit revocation.
Inactivity and downtime never allocate a replacement identity.
Display labels are not authentication and cannot prove a sender's identity.
Client session/thread IDs are separate from AgentTalk node IDs and must be bound
through supported client APIs, never guessed from recent transcript files.

Existing flat registrations and Pi structuredContent envelopes remain readable.
Do not silently migrate or rewrite live folders. Preserve the same registration
shape for every client. Version the non-secret binding, not three credential
formats. Pin one explicit server URL; a different server is not a recovery path.

## Membership lifecycle

One shared host-side module implements these transitions. Client-specific code
must not reimplement them, and the model must not be responsible for them.

| Condition | Required action |
| --- | --- |
| New label, valid invitation | Join as worker; validate role and expected ring; save complete response before another authenticated call. |
| Saved identity, online or offline | Authenticate/resume; keep node_id and credentials; save the complete successful registration. |
| Presence timeout passed | Show offline; retain membership and queued mail. The next authenticated call makes the same identity online. |
| Membership absent or revoked | Stop and require the operator. Never silently replace the identity. |
| Invalid private token | Stop with a safe diagnostic. Do not silently allocate a new identity or try another token. |
| Invalid ring invitation | Stop and require an operator-supplied invitation. Never create a replacement ring. |
| Wrong role, server or ring | Stop without replacing files or changing team selection. |
| Server unreachable | Preserve credentials and identity; bounded retry/backoff; no rejoin based on a network error. |
| Registration save fails | Stop authenticated work and delivery; never use an identity that was not saved. |
| Client closes | Stop its watcher/heartbeat and release ownership. Do not leave a helper maintaining ghost presence. |
| Concurrent launch of same identity | Reject the second owner before it renews or drains mail. |
| Stale ownership lock | Verify owner exit using reliable process/session identity, or require explicit operator recovery. Never steal a possibly live identity based on age alone. |

A lost join response has an uncertain outcome. Add a scoped registration
idempotency key, persisted before a new join and checked by the server, so retry
of that operation cannot allocate duplicate nodes. Authentication is still
required; a key alone must not reveal registration credentials. Do not extend
this retry rule to message sends or receives.

The server is authoritative for membership and presence. An old last_seen in a
local JSON file does not prove inactivity because metadata calls update server
presence without rewriting the client file. Heartbeats run below the configured
presence timeout while the client is alive, independently of model turns.
Long-poll timeouts must exceed server wait grants. Transport session expiry is
not loss of membership.

A persistent broker restart preserves identity and ring, including after long
downtime. Presence timestamps may be slightly stale after a crash; this cannot
delete an identity. Loss of the durable membership store is an operator incident,
not a reason to invent a new ring from client files.

If the operator explicitly replaces a PM, update the authoritative invitation's public
PM pointer after validating and saving that PM's registration. Workers must not
keep blindly sending to an old PM ID or select a replacement by display name.
Across machines, explicitly redistribute the updated invitation.

Offline identities retain accepted mail, subject to bounded capacity for new
sends. Explicit eviction discards that inbox. Archive history is not permission
to replay work. After an explicit replacement, notify peers and reconcile
unfinished work against the project record. Do not claim exactly-once delivery
or execution. Identities already removed by older servers cannot be resurrected.

## Credentials stay outside the model

Startup, resume, new enrollment, heartbeat and file writes run in host code. Generated
prompts, hooks, process arguments, logs and tool results contain no tokens.
Do not ask a model to run jq, sed or cat over membership files, and do not add
broad credential-read permission exceptions to make recovery succeed.

Provide a small credential-bound MCP facade for each session. It exposes peer
IDs, inbox metadata and messaging operations, injects only that session's
credentials upstream, and omits credentials from results. It does not implement
rings, queues, message storage or a second broker. The Elixir broker remains the
only source of truth. The model cannot supply another node's identity or use
registration tools to create or switch rings. This prevents routine credential
exposure; it does not sandbox an unrestricted shell running as the same OS user.
Use supported client read restrictions/sandbox rules for private paths and test
both file tools and shell access. Mode 0600 alone does not isolate secrets from
the model's own user account. Report that limitation instead of claiming a
stronger security boundary.

Use the same shared lifecycle module behind the facade, recovery helper and
watcher. Establish one writer/owner for the membership; do not let a monitor and
a tool call race to update or replace it. Test the facade and ownership boundary before
removing raw authenticated MCP access from existing setups.

Treat a token printed in a transcript as exposed. Do not echo it during diagnosis.
Revoke/replace an active exposed identity through the explicit recovery path and
reconcile work; do not suggest transcript redaction is equivalent to revocation.

## Inbox delivery by client

The shared watcher checks metadata and renews presence, never receives messages.
Emit an event only for actionable mail, authentication failures or connection
state changes, not each empty heartbeat. Use at most one pending wake per head
message, bounded retry and a visible stalled state. The main worker remains the
only inbox receiver. Distinguish collected, accepted and completed.

### Pi

Retain the existing extension's documented idle-turn and busy-follow-up APIs.
Replace its independent credential/recovery behavior with the shared lifecycle.
Keep cancellation, reload and on/off behavior covered by the real-Pi smoke.

### Claude Code

First test the native Monitor tool with the shared watcher: a long-lived command
emits an actionable inbox event and Claude actually handles it while idle, then
handles queued mail after a busy turn. Verify its lifetime, permission behavior,
stop/restart behavior and availability in the user's actual subscription/provider.
A background shell command alone is not proof of turn delivery.

Claude Channels is another documented push API, but currently a research preview
with authentication, plugin allowlist and organization restrictions. Evaluate it
only if Monitor does not meet the contract. Never quietly add a dangerous
channel-development flag or rely on an unavailable preview capability.

Keep /loop as a clearly labelled opt-in fallback with one-minute granularity,
model-turn costs, busy-turn delays and expiry/resume limitations. A loop must
call the credential-bound tools/helper, not materialize credentials in Bash.
It does not qualify as the no-empty-model-turn automatic support tier.

### Codex

Installed Codex 0.171.0 exposes `codex queue --thread ID --message TEXT --resume`.
Use this as the first native delivery candidate, binding the exact thread through
supported session hooks or app-server APIs. Queue success alone is insufficient:
--resume can warn and fail after the message has been queued. Verify that idle
and busy sessions actually process the notification and that no sibling session
receives it. Use the documented app-server turn APIs only if necessary; note
that this surface is experimental and record the tested version.

Do not assume Codex has Claude's /loop semantics. If neither supported route
meets the contract, report the missing capability and ask before introducing a
new session supervisor. No terminal keystroke injection or transcript scraping.

## Status must report evidence

Report registration state, client attachment, last successful heartbeat, watcher
state, pending actionable mail, last requested turn and last verified round trip
separately. Online presence is not proof the model is working. Advertise whether
this session uses native delivery, scheduled polling, manual checks, or is blocked.
Never label a connection 'ready' solely because initialize or list_nodes passed.

## Implementation order and release gates

1. Durable broker membership with separate presence and safe error codes (PR #24).
   Then shared host-side lifecycle, join idempotency, locks and atomic-write
   failure tests. No model involvement; no automatic rejoin for missing identities.
2. Credential-bound tools plus add/resume/status. Test simulated credential-read
   denial; it must not affect host-side recovery. Install a versioned runtime
   outside mutable development worktrees; printed commands refer to that runtime.
3. Platform capability spikes in isolated sessions: Pi baseline, Claude Monitor,
   Codex queue. Record exact versions, permissions, APIs and evidence. Do not
   change live CeleraTax agents to discover whether a feature works.
4. Small platform adapters sharing the same lifecycle and watcher. Publish the
   support matrix only after the matrix below passes for each advertised mode.
5. Migrate one worker of each client into a disposable mixed ring, then migrate
   live workers one at a time with operator approval. No bulk identity reset.

For every supported client test:

- Add to the chosen ring without counts or TOML, preserving all existing agents.
- Delay launch past the presence timeout; resume with the same ID and credentials
  without reading/printing secrets through the model.
- Multiple days offline, queued mail retained, and return with the same identity.
- Broker restart before/after the presence timeout, and server offline/back online.
- Explicit eviction invalidates saved credentials and requires operator action.
- Invalid token, invitation, role/server/ring mismatch and corrupt private JSON.
- Lost registration response, failed atomic save, concurrent calls and launches.
- Idle delivery without user input; queued delivery after a busy turn; no empty
  model turns in the automatic tier; acknowledgments do not create reply loops.
- Cancellation, client exit, process crash, resume, stale locks and changed PM ID.
- No double receiver; uncertain sends/receives are not blindly retried.
- Defaults preserve permissions and existing repository/client configuration.
- Credentials absent from transcript, arguments, diagnostics and operator UI.
- Exact installed version and reproducible live-client smoke, not only mocks.

## References checked

- Claude Code 2.1.311 and Codex CLI 0.171.0 installed locally at planning time.
- https://code.claude.com/docs/en/tools-reference.md#monitor-tool
- https://code.claude.com/docs/en/scheduled-tasks.md
- https://code.claude.com/docs/en/channels.md
- `codex queue --help` and `codex app-server --help` on the installed version.
- This repository's integration contract and real-Pi smoke acceptance description.

Native capabilities are candidates until tested, not claims of completed support.
