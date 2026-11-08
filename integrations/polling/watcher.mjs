import { ClientError } from "./mcp.mjs";

// Runtime independent: the host supplies wake(), status() and credential loading.
// The watcher only calls list_nodes. The main agent remains the sole inbox consumer.
export class InboxWatcher {
  constructor({ client, loadMembership, wake, status = () => {}, intervalMs = 10_000,
    setTimer = setTimeout, clearTimer = clearTimeout }) {
    Object.assign(this, { client, loadMembership, wake, status, intervalMs, setTimer, clearTimer });
    this.failures = 0;
    this.controller = new AbortController();
  }

  start() {
    this.running = true;
    return this.check();
  }

  stop() {
    this.running = false;
    this.clearTimer(this.timer);
    this.controller.abort();
  }

  settled(aborted = false) {
    if (aborted) {
      this.stop();
      this.report("paused", "AgentTalk paused after cancellation; use /agent-talk on to resume.");
      return;
    }
    this.notified = false;
    return this.check();
  }

  check() {
    if (!this.running) return Promise.resolve();
    if (this.inFlight) return this.inFlight;
    this.clearTimer(this.timer);
    this.inFlight = this.poll().finally(() => {
      this.inFlight = undefined;
      if (this.running) {
        const delay = Math.min(60_000, this.intervalMs * 2 ** Math.min(this.failures, 3));
        this.timer = this.setTimer(() => void this.check(), delay);
        this.timer?.unref?.();
      }
    });
    return this.inFlight;
  }

  async poll() {
    try {
      const member = await this.loadMembership();
      if (!this.running) return;
      if (!member) {
        this.report("waiting", "AgentTalk waiting for this session's saved registration.");
        return;
      }
      // Never expose this key, the registration, or raw server errors to callbacks.
      const identity = JSON.stringify([member.node_id, member.token, member.ring_id]);
      if (identity !== this.identity) {
        this.identity = identity;
        this.head = undefined;
        this.attempts = 0;
        this.notified = false;
        this.authNotified = false;
      }
      const result = await this.client.call("list_nodes",
        { node_id: member.node_id, token: member.token }, this.controller.signal);
      if (!this.running) return;
      const inbox = result.inbox;
      if (result.ring_id !== member.ring_id || !Number.isInteger(inbox?.pending_messages) ||
          inbox.pending_messages < 0 || (inbox.pending_messages > 0 &&
            typeof inbox.next_message_id !== "string")) {
        throw new ClientError("protocol", "Update AgentTalk: list_nodes must return inbox metadata.");
      }
      this.failures = 0;
      this.authNotified = false;
      if (inbox.next_message_id !== this.head) {
        this.head = inbox.next_message_id;
        this.attempts = 0;
      }
      if (inbox.pending_messages === 0) {
        this.report("watching", "AgentTalk watching inbox");
      } else if (this.attempts >= 3 && !this.notified) {
        this.report("stalled", "AgentTalk inbox still unread after three wake-ups; check the session.");
      } else if (!this.notified) {
        this.notified = true;
        this.attempts++;
        await this.wake({ kind: "inbox", node_id: member.node_id, role: member.role,
          ring_id: member.ring_id, pending_messages: inbox.pending_messages });
        this.report("pending", "AgentTalk inbox: " + inbox.pending_messages + " · turn requested");
      }
    } catch (error) {
      if (!this.running) return;
      this.failures++;
      if (["expired", "token"].includes(error.code)) {
        this.report("registration", error.message);
        if (!this.authNotified) {
          this.authNotified = true;
          await this.wake({ kind: "recovery" });
        }
      } else {
        this.report("error", error instanceof ClientError ? error.message :
          "AgentTalk inbox check failed; retrying automatically.");
      }
    }
  }

  report(state, message) {
    const signature = state + ":" + message;
    if (signature !== this.lastStatus) {
      this.lastStatus = signature;
      this.status({ state, message });
    }
  }
}
