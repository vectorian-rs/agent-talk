# CLI onboarding

One team folder, one membership per agent. No roster or worker count.
The CLI prepares files and prints a command; you launch the client yourself.
Repository instructions still own project work and approval gates.

## Add one worker

From your project root, with Node 24+ installed:

```sh
node /path/to/agent-talk/cli/agent-talk.mjs add cc-w5 --team manual-4 --client claude
```

Run the printed `cd … && claude …` command in a separate terminal. Use another
unused label for another agent, or `--client pi` to prepare a Pi worker.
The team name, label and client are required. Nothing is inferred or numbered.
You can optionally install the command with `npm link --ignore-scripts` from
`cli/`, then use `agent-talk add …` instead of the full Node command.

The server defaults to `http://127.0.0.1:4000/mcp`. Use `--server URL` for another
server. The command never reads or writes `agent-talk.toml`.

## Files

For the example above:

```text
.agent-talk/manual-4/
  pm.json                     existing PM registration, if available
  invitation.json             ring invitation and public PM/ring IDs
  cc-w5.json                  new private worker registration
  cc-w5.json.claude/
    mcp.json                  MCP connection
    settings.json             turn-boundary inbox hooks
    transport.json            membership path, PM ID and transport instructions
```

Either `invitation.json` or `pm.json` must exist before adding a worker. If only
`pm.json` exists, the CLI verifies the saved PM with the server and copies only
the invitation and public IDs. It never copies the private PM node token.
Expired PM credentials require the operator to resume that PM first.

A missing or empty folder is an error. It is never treated as a new ring.
Existing memberships are not overwritten or reused by add. Choose another
label if one already exists. Labels and team names contain 1..64 letters,
digits, underscores or hyphens, starting with a letter or digit. Worker labels
`pm` and `invitation` are reserved.

Private registrations are saved atomically with mode 0600. The team directory
is private, and the CLI adds `/.agent-talk/` to `.gitignore` if necessary.
Claude's connection, settings and transport files contain no bearer credentials.
Its generated command references files, not tokens. Shared Claude settings and
repository instructions are not replaced. Approve MCP/tool access when asked.

The short-lived `allocation.lock` prevents simultaneous additions overwriting
each other's files. If an allocation process is killed, confirm it is stopped
before removing that lock. No background session manager is involved. Run each
printed native client command only once; the CLI cannot detect duplicate native
sessions using the same membership.

## Inbox and recovery

Claude checks its inbox during onboarding and uses `SessionStart` and
`UserPromptSubmit` hooks to report pending mail. These checks renew its lease
without receiving messages; the model uses the MCP communicate tool to receive.
An idle Claude session is not awakened automatically. Prompt it to check its
inbox when needed. Pi keeps its existing background watcher.

Keep the printed command to restart that session later, using the same files
only after its previous process is stopped. On expiry, the transport instructions
tell Claude to rejoin the saved ring, save the full registration privately, and
notify the verified PM of the changed identity. Invalid invitations need the
operator, never a silently created ring. Reconcile work with the project record.

The legacy `init` and `start` commands still support existing TOML-based projects.
They are not required by this file-based add flow. Creating a new PM ring remains
an explicit action through the existing MCP/manual onboarding; add only joins.

Tests use temporary folders and fake brokers/clients, never live CeleraTax rings.
They cover preparing files without TOML, preserving existing agents, explicit
selection, rejected duplicate labels, native command execution and inbox hooks.
A real model's compliance and permissions still need operator confirmation.

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
