import { ClientError } from "./mcp.mjs";

// Runtime independent: the host supplies wake(), status() and credential loading.
// The watcher only calls list_nodes. The main agent remains the sole inbox consumer.
export class InboxWatcher {
  constructor({ client, loadMembership, wake, status = () => {}, intervalMs = 10_000,
    setTimer = setTimeout, clearTimer = clearTimeout, labels = {} }) {
    this.client = client;
    this.loadMembership = loadMembership;
    this.wake = wake;
    this.status = status;
    this.intervalMs = intervalMs;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.labels = labels;
    this.controller = new AbortController();
    // Mutable poll state.
    this.running = false;
    this.paused = false;
    this.waitingForMembership = false;
    this.notified = false;
    this.authNotified = false;
    this.failures = 0;
    this.attempts = 0;
    this.pollIntervalMs = intervalMs;
    this.identity = undefined;
    this.head = undefined;
    this.inFlight = undefined;
    this.timer = undefined;
    this.lastStatus = undefined;
    this.lastCheck = undefined;
    this.lastWake = undefined;
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
    if (!this.running) return Promise.resolve();
    this.paused = aborted;
    this.notified = false;
    return this.check();
  }

  resume() {
    if (!this.running || !this.paused) return Promise.resolve();
    this.paused = false;
    this.attempts = 0;
    this.authNotified = false;
    return this.check();
  }

  check() {
    if (!this.running) return Promise.resolve();
    if (this.inFlight) return this.inFlight;
    this.clearTimer(this.timer);
    this.inFlight = this.poll().finally(() => {
      this.inFlight = undefined;
      if (this.running) {
        const delay = this.waitingForMembership ? 250 :
          Math.min(60_000, this.pollIntervalMs * 2 ** Math.min(this.failures, 3));
        this.timer = this.setTimer(() => void this.check(), delay);
        this.timer?.unref?.();
      }
    });
    return this.inFlight;
  }

  async poll() {
    try {
      this.waitingForMembership = false;
      const member = await this.loadMembership();
      if (!this.running) return;
      if (!member) {
        this.waitingForMembership = true;
        this.report("waiting", "AgentTalk waiting for this session's saved registration.");
        return;
      }
      this.pollIntervalMs = Number.isFinite(member.expires_in_seconds) && member.expires_in_seconds > 0 ?
        Math.min(this.intervalMs, Math.max(100, member.expires_in_seconds * 1000 / 3)) : this.intervalMs;
      // Never expose this key, the registration, or raw server errors to callbacks.
      const identity = JSON.stringify([member.node_id, member.token, member.ring_id]);
      if (identity !== this.identity) {
        this.identity = identity;
        this.head = undefined;
        this.attempts = 0;
        this.notified = false;
        this.authNotified = false;
      }
      // Registration-confirmed labels are authoritative; renewals must not
      // drift from them. this.labels only covers memberships saved without
      // labels, where the server echoes node_id as the name — not a label.
      const text = (value) => typeof value === "string" && value.length > 0;
      const labels = {
        ...this.labels,
        ...(text(member.project) ? { project: member.project } : {}),
        ...(text(member.name) && member.name !== member.node_id ? { name: member.name } : {}),
      };
      const result = await this.client.call("list_nodes",
        { ...labels, node_id: member.node_id, token: member.token }, this.controller.signal);
      if (!this.running) return;
      const inbox = result.inbox;
      if (result.ring_id !== member.ring_id || !Number.isInteger(inbox?.pending_messages) ||
          inbox.pending_messages < 0 || (inbox.pending_messages === 0 ? inbox.next_message_id !== null :
            typeof inbox.next_message_id !== "string" || inbox.next_message_id.length === 0)) {
        throw new ClientError("protocol", "Update AgentTalk: list_nodes must return inbox metadata.");
      }
      this.lastCheck = new Date().toISOString();
      this.authNotified = false;
      if (inbox.next_message_id !== this.head) {
        this.head = inbox.next_message_id;
        this.attempts = 0;
      }
      if (this.paused) {
        this.report("paused", "AgentTalk monitoring inbox; automatic turns paused after cancellation. " +
          "Send a prompt or use /agent-talk on to resume.");
      } else if (inbox.pending_messages === 0) {
        this.report("watching", "AgentTalk watching inbox");
      } else if (this.attempts >= 3 && !this.notified) {
        this.report("stalled", "AgentTalk inbox still unread after three wake-ups; check the session.");
      } else if (!this.notified) {
        this.notified = true;
        this.attempts++;
        const sent = await this.requestWake({ kind: "inbox", node_id: member.node_id, role: member.role,
          ring_id: member.ring_id, pending_messages: inbox.pending_messages });
        if (!sent) {
          this.notified = false;
          this.attempts = Math.max(0, this.attempts - 1);
          return;
        }
        this.report("pending", "AgentTalk inbox: " + inbox.pending_messages + " · turn requested");
      }
      this.failures = 0;
    } catch (error) {
      if (!this.running) return;
      this.failures++;
      if (["expired", "token"].includes(error.code)) {
        this.report("registration", error.message);
        if (!this.paused && !this.authNotified) {
          this.authNotified = true;
          if (!await this.requestWake({ kind: "recovery" })) this.authNotified = false;
        }
      } else {
        this.report("error", error instanceof ClientError ? error.message :
          "AgentTalk inbox check failed; retrying automatically.");
      }
    }
  }

  async requestWake(event) {
    try {
      await this.wake(event);
      if (!this.running) return false;
      this.lastWake = new Date().toISOString();
      return true;
    } catch {
      this.failures++;
      this.report("error", "AgentTalk could not request a turn; retrying automatically.");
      return false;
    }
  }

  report(state, message) {
    if (!this.running) return;
    const signature = state + ":" + message;
    if (signature !== this.lastStatus) {
      this.lastStatus = signature;
      this.status({ state, message });
    }
  }
}
