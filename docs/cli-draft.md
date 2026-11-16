# CLI onboarding

The CLI starts only the named session. Pi and Claude Code can share one ring.
Project instructions, assignments and approval gates remain owned by the
repository and client, not by the launcher.

## Install

Node 24+ is required. From the AgentTalk checkout:

```sh
cd cli
npm ci --ignore-scripts
npm link --ignore-scripts
```

Without linking, replace `agent-talk` with
`node /absolute/path/to/agent-talk/cli/agent-talk.mjs`.

## Three commands

Run these from the project root:

```sh
agent-talk init --client pi --workers 4
agent-talk start pm
```

Init writes `agent-talk.toml`, prepares private state, and prints full launch
commands. It does not register agents. Start the PM before workers, in its own
terminal. A new PM creates the ring; subsequent starts renew its identity or
rejoin its saved ring after expiry.

To add a worker to that ring:

```sh
agent-talk add cc-w5 --client claude
agent-talk start cc-w5
```

Add configures one additional worker and prints its launch command. Start
registers or resumes it, saves the complete response privately, and launches
only its selected client. Labels are independent of the role: every additional
agent is a worker. There is no four-worker ceiling on additions. Labels contain
1..64 letters, digits, underscores or hyphens, starting with a letter or digit;
`pm` and `invitation` are reserved.

Omit `--client` to use the project default for a new label. Repeating add for an
existing label uses its current client unless explicitly specified. A different
client for an existing label is rejected rather than silently replacing it.

Add never launches a session or creates a ring. An existing PM invitation is
required. Start workers in separate terminals. Never give two live sessions
the same identity. Use separate approved branches/worktrees for concurrent
coding; the CLI does not manage project branches.

## Adopt a manually launched ring

For a team already using `.agent-talk/manual-4/pm.json`:

```sh
agent-talk init --client pi --workers 4 --team manual-4
agent-talk add cc-w5 --client claude
agent-talk start cc-w5
```

Do not start another PM if the existing one is running. The first addition
or worker start reads the saved PM, authenticates it with `list_nodes`, checks
its ring and PM identity, and saves `invitation.json` containing only `ring_id`,
`ring_token` and `pm_id`. The PM's private node token is never copied.

If `invitation.json` already exists, it is used as-is. Invalid, corrupt or
expired state fails instead of creating or selecting a replacement ring.
Resume an expired PM using its existing client before importing its invitation.
An existing `agent-talk.toml` is never silently switched to another team;
conflicting init options fail. Edit the configuration explicitly if needed.

## Configuration and private files

Example mixed-client configuration:

```toml
server = "http://127.0.0.1:4000/mcp"
client = "pi"
project = "celeratax"
team = "manual-4"
workers = 4

[agents.cc-w5]
client = "claude"
```

`workers` is the initial `w-1` through `w-N` roster (1..4), not a total ring
limit. Additional labels are recorded in `agents`. Add preserves configuration
values, reserializing TOML, so comments and formatting may change. Configuration
updates are atomic and concurrent additions are excluded with a private lock.
If an add process is killed abruptly, confirm it has stopped before removing
`.agent-talk/add.lock` and retrying.

Each membership is `.agent-talk/<team>/<label>.json`, written atomically with
mode 0600. The team directory is private and ignored by Git. Existing membership
files are never cloned into new workers. Authentication errors do not silently
fall back to a fresh identity. Only expiry rejoins the saved ring; after a
changed identity, reconcile work and notify peers.

Pi receives its existing transport extension and membership flags. Its shared
`.pi/mcp.json` connection is merged without removing other servers. Claude
launches do not modify `.pi/mcp.json` or shared `.claude` settings.

For Claude, the launcher generates these session-local files:

```text
.agent-talk/<team>/<label>.json.claude/
  mcp.json        MCP connection, passed with --mcp-config
  settings.json   Inbox hooks, passed with --settings
  transport.json Membership path, logical label, PM ID and transport instructions
```

These binding files contain no bearer credentials. Credentials stay only in
the membership and invitation files. The session receives a reference to its
transport instructions, not a replacement project system prompt or workflow.
It verifies the ring and PM using `list_nodes` and sends its joined message.
Approve the MCP connection and required tool permissions in Claude Code.

## Inbox checks and limitations

Claude's `SessionStart` and `UserPromptSubmit` hooks invoke:

```sh
agent-talk inbox /absolute/path/to/membership.json --server http://127.0.0.1:4000/mcp
```

Inbox checks authenticate, renew the lease and report the pending count without
receiving. The model uses the MCP `communicate` tool to receive and process mail.
Hooks do not log tokens, drain messages, repeatedly prompt the model, or wake an
idle Claude session. Ask an idle worker to check its inbox when needed. Pi's
background watcher remains unchanged. Automatic Claude idle delivery is not
implemented.

Start holds a per-membership `.session.lock` until its client exits, including
on launch failure or forwarded SIGINT/SIGTERM. A duplicate CLI launch fails
before contacting the broker. Manually launched clients do not participate in
this lock, and abrupt kills can leave stale locks. Stop the old client before
removing a reported lock. The CLI never automatically steals an identity.

All CLI tests use temporary projects and fake brokers/clients. They must not
join or mutate live CeleraTax rings during development. Fake-client launch tests
cover file binding, hook execution, renewal, duplicate ownership, signal
forwarding and missing executables. A live model's willingness and permissions
to follow onboarding instructions still need operator confirmation.

## Message presentation

Keep the original body and first protocol line. Start with safe, clickable full
HTTP(S) URLs in the operator UI; preserve line breaks and escape HTML.

Next, add an explicit repository URL to project configuration and registration
metadata. Capture it with each history event. Then `#482`, `#455` and `9cd32e9c`
can link to the sender's repository. Do not infer repository ownership from a
display name or assume every ring belongs to the same project.

For the example assignment, display `pick up #482 lens:contract` as the title,
with linked issue/source references and the original revision, scope,
constraints, delivery and reply instructions beneath it. Do not infer approved
revision 3 from text saying its fixes are pending. Protocol parsing, full Markdown,
editable message envelopes and automatic semantic rewriting are outside this draft.
