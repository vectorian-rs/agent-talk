# CLI draft

Branch: `feat/onboarding-cli`. The separate worktree contains this draft; the
running checkout and server remain unchanged. This is an initial prototype,
not the supported onboarding path yet.

## Scope and decisions

- The human starts each session. The CLI starts only its named client process.
- `agent-talk.toml` is shared project configuration; no environment overrides.
- `init` creates private directories, adds the ignore rule, configures Pi's MCP
  connection without removing other servers, and prints complete launch commands.
- `start pm` registers/resumes the PM and privately saves its invitation.
  `start w-N` joins that team; no copied invitation or credential-bearing prompt.
- Registration is saved atomically before client launch. Invalid private tokens
  fail; expiry rejoins with the existing invitation. A failed join never creates
  a replacement PM ring silently.
- Existing MCP tools and the Pi inbox watcher are reused. Only Pi launch is
  implemented initially. Other hosts need their own tested scheduling adapter.
- The Node CLI shares the existing Node integration runtime. Its one dependency
  is the [smol-toml parser](https://github.com/squirrelchat/smol-toml), pinned by
  the lockfile. No custom TOML parser or extra Elixir server process is involved.

## Draft usage

Install dependencies inside this worktree once:

```sh
cd /Users/l1x/code/home/agent-talk-cli/cli
npm ci --ignore-scripts
```

From a disposable project with `AGENTS.md` and role instructions:

```sh
node /Users/l1x/code/home/agent-talk-cli/cli/agent-talk.mjs init --client pi --workers 4 --pm-prompt path/to/pm.md --worker-prompt path/to/worker.md
```

`init` prints five complete commands, including the working directory and
executable path. Start PM first, then each worker in its own terminal. The launcher
supplies role instructions and membership paths; there is no startup prompt to paste.
Packaging a standalone `agent-talk` executable remains a follow-up.

The config contains `server`, `client`, `project`, `team`, `workers`, `pm_prompt`
and `worker_prompt`. State lives under `.agent-talk/<team>/`. Choose a new team
name explicitly for an independent ring. Secrets never enter launch arguments.

## Acceptance and verification

- Init is repeatable and preserves other MCP servers and ignore entries.
- PM and four workers get distinct, private memberships in one ring.
- Workers need that team's invitation; mismatched roles/rings and bad tokens fail.
- Prompt arguments contain paths and public IDs, never bearer credentials.
- Existing Pi polling tests remain green after MCP client reuse.
- All tests use disposable directories and fake/isolated servers. Never run this
  draft against the current CeleraTax or Hiko team during development.

Draft verification: 57 Elixir tests and 37 Node tests pass; formatting and diff
checks pass. Self-review found and fixed an expired PM registration without an
invitation accidentally falling through to a fresh ring; a regression now guards
that boundary. The running checkout's source fingerprint and listening server PID
were unchanged throughout this draft.

Before this becomes the default: add exclusive session ownership and stale-lock
recovery, process/signal tests, actual CLI-to-Pi smoke coverage, `status` with
separate registration/polling/round-trip evidence, and packaging. The existing
in-memory message delivery limits remain unchanged.

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
