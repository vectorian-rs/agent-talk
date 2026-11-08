import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { resolve } from "node:path";
import { McpClient, readMembership } from "../polling/mcp.mjs";
import { InboxWatcher } from "../polling/watcher.mjs";

const settingsType = "agent-talk-inbox-settings";

export default function agentTalk(pi: ExtensionAPI) {
  let watcher: InboxWatcher | undefined;
  let settings: { file: string; url: string; session: string; enabled: boolean } | undefined;
  let state = "off";

  pi.registerFlag("agent-talk-membership", {
    type: "string", description: "This session's saved AgentTalk registration JSON file",
  });
  pi.registerFlag("agent-talk-url", {
    type: "string", default: "http://127.0.0.1:4000/mcp", description: "AgentTalk MCP URL",
  });

  function stop() {
    watcher?.stop();
    watcher = undefined;
  }

  async function start(ctx: ExtensionContext) {
    stop();
    if (!settings?.enabled) return;
    const file = settings.file;
    watcher = new InboxWatcher({
      client: new McpClient(settings.url),
      loadMembership: () => readMembership(file),
      wake: (event: { kind: string; node_id?: string; pending_messages?: number }) => {
        const content = event.kind === "recovery" ?
          "AgentTalk rejected this session's saved membership. Read " + JSON.stringify(file) +
          " privately. Follow the project's recovery instructions: rejoin the existing ring " +
          "with role and ring_token if necessary, save the complete successful response " +
          "atomically with mode 0600, and notify peers of a changed ID. " +
          "An invalid ring invitation requires the operator. Do not create another PM ring " +
          "as recovery, print credentials, or retry registration endlessly." :
          "AgentTalk inbox notification for " + event.node_id + ": " +
          event.pending_messages + " queued message(s). Read this session's registration " +
          "privately from " + JSON.stringify(file) + ' and call communicate(action="receive") ' +
          "using its node_id and token. This notification has not removed any mail. " +
          "Handle every received message under your project role instructions without " +
          "waiting for the human to resume you. Verify senders and claims. Workers send " +
          "receipt and acceptance/blocked replies, perform authorized work, then send " +
          "results to the PM. The PM processes worker replies and assigns the next " +
          "authorized work. A local print is not a reply: send via communicate. " +
          "Do not acknowledge acknowledgments or bypass human approval gates. " +
          "The host checks for new mail; do not start a polling loop.";
        pi.sendMessage({ customType: "agent-talk-inbox", content, display: true },
          { triggerTurn: true, deliverAs: "followUp" });
      },
      status: ({ state: nextState, message }: { state: string; message: string }) => {
        state = nextState;
        if (!ctx.hasUI) return;
        ctx.ui.setStatus("agent-talk", message);
        if (["stalled", "paused", "registration"].includes(nextState)) ctx.ui.notify(message, "warning");
      },
    });
    await watcher.start();
  }

  pi.on("session_start", async (event, ctx) => {
    stop();
    settings = undefined;
    state = "off";
    if (ctx.hasUI) ctx.ui.setStatus("agent-talk", undefined);
    const session = ctx.sessionManager.getSessionId();
    // Do not silently attach a new or forked session to its parent's membership.
    if (["new", "fork"].includes(event.reason)) return;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === settingsType) {
        const saved = entry.data as typeof settings;
        if (saved?.session === session) settings = saved;
      }
    }
    const file = pi.getFlag("agent-talk-membership");
    if (!settings && event.reason === "startup" && typeof file === "string" && file) {
      settings = { file: resolve(ctx.cwd, file), url: String(pi.getFlag("agent-talk-url")),
        session, enabled: true };
      pi.appendEntry(settingsType, settings);
    }
    await start(ctx);
  });

  pi.on("agent_settled", async (event) => {
    await watcher?.settled(event.aborted);
    if (event.aborted && settings) {
      settings.enabled = false;
      pi.appendEntry(settingsType, settings);
      state = "paused";
    }
  });
  pi.on("session_shutdown", () => { stop(); });

  pi.registerCommand("agent-talk", {
    description: "Automatic inbox: on [membership.json], off, or status",
    handler: async (args, ctx) => {
      const match = args.trim().match(/^(on|off|status)(?:\s+(.+))?$/);
      if (!match || match[1] === "status") {
        if (ctx.hasUI) ctx.ui.notify(settings?.enabled ?
          "AgentTalk " + state + ": " + settings.file : "AgentTalk inbox integration is off.", "info");
        return;
      }
      if (match[1] === "off") {
        stop();
        state = "off";
        if (settings) {
          settings.enabled = false;
          pi.appendEntry(settingsType, settings);
        }
        if (ctx.hasUI) ctx.ui.setStatus("agent-talk", "AgentTalk automatic inbox off");
        return;
      }
      const file = match[2] ?? settings?.file;
      if (!file) {
        if (ctx.hasUI) ctx.ui.notify("Use /agent-talk on .agent-talk/<session>.json", "warning");
        return;
      }
      settings = { file: resolve(ctx.cwd, file), url: settings?.url ??
        String(pi.getFlag("agent-talk-url")), session: ctx.sessionManager.getSessionId(),
        enabled: true };
      pi.appendEntry(settingsType, settings);
      await start(ctx);
    },
  });
}
