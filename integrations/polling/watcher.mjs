import { ClientError, validateInboxMetadata } from "./mcp.mjs";

// Every check asks for this flat wait; the server clamp is the single authority
// on the grant. McpClient.call derives the HTTP timeout from wait_seconds (the
// clamped grant plus slack), so no separate timeout constant is needed here.
const WATCH_WAIT_SECONDS = 25;

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
    this.immediate = false;
    this.identity = undefined;
    this.head = undefined;
    this.inFlight = undefined;
    this.runId = 0;
    this.timer = undefined;
    this.lastStatus = undefined;
    this.lastCheck = undefined;
    this.lastWake = undefined;
  }

  start() {
    this.running = true;
    // stop() aborts the controller; a restart on the same instance needs a fresh
    // one, or every request would abort on the already-aborted signal.
    if (this.controller.signal.aborted) this.controller = new AbortController();
    return this.check();
  }

  stop() {
    this.running = false;
    // Invalidate the in-flight poll's continuation and drop its handle, so a
    // restart begins a fresh check at once instead of reusing the aborted poll,
    // whose backoff would otherwise delay the next check.
    this.runId++;
    this.inFlight = undefined;
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
    const runId = this.runId;
    this.inFlight = this.poll(runId).finally(() => {
      // A stop() since this poll began bumped runId; its continuation must not
      // clear a newer run's in-flight handle or schedule a stale retry.
      if (runId !== this.runId) return;
      this.inFlight = undefined;
      if (this.running) {
        // One scheduling rule: an empty reply the server held open resumes the
        // watch immediately (the server already paced us); anything else —
        // mail pending, an unwaited or old-server reply, pauses, errors —
        // keeps interval pacing and backoff.
        const delay = this.waitingForMembership ? 250 :
          this.immediate ? 0 :
          Math.min(60_000, this.pollIntervalMs * 2 ** Math.min(this.failures, 3));
        this.timer = this.setTimer(() => void this.check(), delay);
        this.timer?.unref?.();
      }
    });
    return this.inFlight;
  }

  // A stop() bumps runId; a run must bail after every async step if it was
  // stopped (and possibly restarted) meanwhile, or it would issue a second
  // request on the restart's controller.
  stale(runId) {
    return !this.running || runId !== this.runId;
  }

  async poll(runId) {
    try {
      this.waitingForMembership = false;
      this.immediate = false;
      const member = await this.loadMembership();
      if (this.stale(runId)) return;
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
        { ...labels, node_id: member.node_id, token: member.token,
          wait_seconds: WATCH_WAIT_SECONDS },
        this.controller.signal);
      if (this.stale(runId)) return;
      const inbox = validateInboxMetadata(result, member.ring_id,
        "Update AgentTalk: list_nodes must return inbox metadata.");
      // Older servers do not send pending_actionable; every message is actionable there.
      const actionable = inbox.pending_actionable ?? inbox.pending_messages;
      this.lastCheck = new Date().toISOString();
      this.authNotified = false;
      if (inbox.next_message_id !== this.head) {
        this.head = inbox.next_message_id;
        this.attempts = 0;
      }
      if (this.paused) {
        this.report("paused", "AgentTalk monitoring inbox; automatic turns paused after cancellation. " +
          "Send a prompt or use /agent-talk on to resume.");
      } else if (actionable === 0) {
        this.immediate = typeof result.waited_seconds === "number" && result.waited_seconds > 0;
        this.report("watching", "AgentTalk watching inbox");
      } else if (this.attempts >= 3 && !this.notified) {
        this.report("stalled", "AgentTalk inbox still unread after three wake-ups; check the session.");
      } else if (!this.notified) {
        this.notified = true;
        this.attempts++;
        const sent = await this.requestWake({ kind: "inbox", node_id: member.node_id, role: member.role,
          ring_id: member.ring_id, pending_messages: inbox.pending_messages,
          pending_actionable: actionable }, runId);
        // A stop() during the wake must not let this run clear the restarted
        // run's notified flag, which would let it wake a second time.
        if (this.stale(runId)) return;
        if (!sent) {
          this.notified = false;
          this.attempts = Math.max(0, this.attempts - 1);
          // A failed wake here is the only failure this success path saw, so
          // count it for backoff; the catch block already counts its own.
          this.failures++;
          return;
        }
        this.report("pending", "AgentTalk inbox: " + actionable + " actionable · turn requested");
      }
      this.failures = 0;
    } catch (error) {
      if (this.stale(runId)) return;
      this.failures++;
      if (["expired", "token"].includes(error.code)) {
        this.report("registration", error.message);
        if (!this.paused && !this.authNotified) {
          this.authNotified = true;
          const woke = await this.requestWake({ kind: "recovery" }, runId);
          if (this.stale(runId)) return;
          if (!woke) this.authNotified = false;
        }
      } else {
        this.report("error", error instanceof ClientError ? error.message :
          "AgentTalk inbox check failed; retrying automatically.");
      }
    }
  }

  async requestWake(event, runId) {
    try {
      await this.wake(event);
      if (this.stale(runId)) return false;
      this.lastWake = new Date().toISOString();
      return true;
    } catch {
      // A stale run (stopped, maybe restarted) must not overwrite the live run's
      // status with this error. The caller owns failure counting.
      if (this.stale(runId)) return false;
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
