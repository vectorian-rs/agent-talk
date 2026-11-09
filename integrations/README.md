# Automatic inbox integration

AgentTalk stays an MCP broker with three tools. An optional host adapter supplies
the missing step: start or queue an agent turn when its inbox has mail.

| Part | Responsibility |
| --- | --- |
| Elixir broker | Membership, ring isolation, queues, inbox metadata, operator UI. |
| Shared watcher (`polling/`) | Check metadata every 10 seconds while connected (sooner for short leases), renew presence, retry connections, request a turn. |
| Host adapter (`pi/agent-talk.ts`) | Bind one membership file to a session, deliver notifications, stop on explicit off or shutdown. |
| Role prompt | Receive mail, verify the sender and assignment, do authorized work, send replies/results. |

The Pi adapter uses the documented
[`sendMessage` turn and follow-up support](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md#pisendmessagemessage-options).
It can wake an idle session and queue a notification while the session is busy.
The watcher never removes mail; the main agent is the sole receiver. A dead
watcher therefore leaves unread messages on the server.

Pi announces `project` (the checkout directory name) and `name` (project plus
membership filename) with inbox checks. These display labels do not change
server IDs or credentials. The operator selects one ring to view at a time.

A future host adapter reuses `InboxWatcher` by providing:

- `loadMembership()`: read this session's saved complete registration privately;
  the reader extracts `structuredContent` when Pi saves the full MCP result.
- `wake(event)`: deliver an inbox notification and start/queue an agent turn.
- `status(event)`: show connection, registration, cancellation or stalled state.
- Lifecycle: `start()`; `settled(aborted)` at final idle; `resume()` on a human
  prompt; `stop()` on explicit off or shutdown. Cancellation pauses wake-ups while
  metadata checks continue. A human prompt resumes them.

Do not implement `wake` as a terminal notification alone. A supported adapter must
prove that an idle agent runs and a busy agent handles its queued notification
without another human prompt. A runtime without turn scheduling needs a supervised
session runner; a prompt or generic MCP connection cannot add that capability.
Claude and Codex adapters remain future work.

The host owns polling; agents do not run polling loops or create extra agents.
Role prompts must handle notifications automatically, send actual replies, and
preserve human approval gates. Receipt, acceptance and completion are distinct.
No replies to acknowledgments. Missing/expired membership invokes the project's
recovery flow, preserving ring ownership and saving every successful response
before the watcher can use it. Invalid invitations require operator intervention.

Memberships persist locally; messages remain in memory. Receiving removes
messages before the client response; message loss is possible on a failed receive,
membership expiry or server restart. Automatic wake-up does not provide durable
delivery. GitHub or the project's equivalent remains the work record.

Run the Node tests and `mix run --no-start examples/pi_smoke.exs` from the repository
root. The smoke starts an isolated broker and three real Pi runtimes using a
scripted local model. Registration and messaging use Pi's built-in MCP tools,
including the saved result envelope. It verifies transport, tools and wake-up
mechanics, then restarts the isolated server and repeats the exchange with the
same Pi sessions and credentials. It also checks cancellation and resumption,
multiline command rejection, reload, busy follow-ups and explicit on/off.
It does not evaluate a real model's compliance with project prompts.
