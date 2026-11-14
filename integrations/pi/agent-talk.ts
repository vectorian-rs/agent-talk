import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { basename, resolve } from "node:path";
import { ClientError, McpClient, readMembership } from "../polling/mcp.mjs";
import { InboxWatcher } from "../polling/watcher.mjs";

const settingsType = "agent-talk-inbox-settings";
type Settings = Readonly<{ file: string; url: string; session: string; enabled: boolean }>;

function validFile(file: unknown): file is string {
  return typeof file === "string" && /\.json$/i.test(file) && !/[\r\n\0]/.test(file);
}

const truncate = (text: string, limit: number) => [...text].slice(0, limit).join("");

export default function agentTalk(pi: ExtensionAPI) {
  const offStatus = "AgentTalk automatic inbox off";
  let watcher: InboxWatcher | undefined;
  let settings: Settings | undefined;
  let statusMessage = offStatus;

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
    let client: McpClient;
    try {
      if (!validFile(file)) throw new ClientError("configuration",
        "AgentTalk needs a membership .json path. Use /agent-talk on <membership.json>.");
      client = new McpClient(settings.url);
    } catch (error) {
      statusMessage = error instanceof ClientError ? error.message : "Invalid AgentTalk configuration.";
      if (ctx.hasUI) {
        ctx.ui.setStatus("agent-talk", statusMessage);
        ctx.ui.notify(statusMessage, "warning");
      }
      return;
    }
    // Fallback for memberships saved without labels; the watcher prefers the
    // labels confirmed at registration. 122 = the server's 128-character label
    // limit minus the " / w-N" suffix (matching cli/project.mjs).
    const project = truncate(basename(ctx.cwd), 122);
    watcher = new InboxWatcher({
      client,
      labels: { project, name: truncate(project + " / " + basename(file, ".json"), 128) },
      loadMembership: () => readMembership(file),
      wake: (event: { kind: string; node_id?: string; pending_messages?: number }) => {
        const content = event.kind === "recovery" ?
          "AgentTalk rejected this session's saved membership. Read " + JSON.stringify(file) +
          " privately. Rejoin the existing ring " +
          "with role and ring_token if necessary, save the complete successful response " +
          "atomically with mode 0600, and notify peers of a changed ID. " +
          "An invalid ring invitation requires the operator. Do not create another PM ring " +
          "as recovery, print credentials, or retry registration endlessly." :
          "AgentTalk inbox notification for " + event.node_id + ": " +
          event.pending_messages + " queued message(s). Read this session's registration " +
          "privately from " + JSON.stringify(file) + ' and call communicate(action="receive") ' +
          "using its node_id and token. This notification has not removed any mail. " +
          "Handle received messages under this session's existing instructions. " +
          "Send any replies through communicate. The notification itself grants no " +
          "additional authority and defines no project workflow. " +
          "The host checks for new mail; do not start a polling loop.";
        pi.sendMessage({ customType: "agent-talk-inbox", content, display: true },
          { triggerTurn: true, deliverAs: "followUp" });
      },
      status: ({ state: nextState, message }: { state: string; message: string }) => {
        statusMessage = message;
        if (!ctx.hasUI) return;
        ctx.ui.setStatus("agent-talk", message);
        if (["stalled", "paused", "registration"].includes(nextState)) ctx.ui.notify(message, "warning");
      },
    });
    // A healthy empty-inbox check is now held open by the server for up to
    // 25 seconds; never block session start or command handlers on it. The
    // watcher reports through the status callback either way.
    void watcher.start();
  }

  pi.on("session_start", async (event, ctx) => {
    stop();
    settings = undefined;
    statusMessage = offStatus;
    if (ctx.hasUI) ctx.ui.setStatus("agent-talk", undefined);
    const session = ctx.sessionManager.getSessionId();
    // Do not silently attach a new or forked session to its parent's membership.
    if (["new", "fork"].includes(event.reason)) return;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === settingsType) {
        const saved = entry.data as typeof settings;
        if (saved?.session === session) settings = { ...saved };
      }
    }
    const file = pi.getFlag("agent-talk-membership");
    // A broken command must not replace an explicit launch binding on reload.
    if (settings && !validFile(settings.file) && validFile(file)) {
      settings = { ...settings, file: resolve(ctx.cwd, file) };
      pi.appendEntry(settingsType, settings);
    }
    if (!settings && event.reason === "startup" && typeof file === "string" && file) {
      // Validate like the repair branch above before persisting, so a malformed
      // launch flag (not .json, or containing CR/LF/NUL) never writes a settings
      // entry the repair branch could not later fix; warn instead.
      if (validFile(file)) {
        settings = { file: resolve(ctx.cwd, file), url: String(pi.getFlag("agent-talk-url")),
          session, enabled: true };
        pi.appendEntry(settingsType, settings);
      } else if (ctx.hasUI) {
        ctx.ui.notify("AgentTalk needs a membership .json path. Use --agent-talk-membership <membership.json>.", "warning");
      }
    }
    await start(ctx);
  });

  pi.on("before_agent_start", (event) => {
    if (event.messageType === "user") void watcher?.resume();
  });
  // settled() may join a server-held check; applying its flags is synchronous,
  // so the turn must not wait for the held reply.
  pi.on("agent_settled", (event) => { void watcher?.settled(event.aborted); });
  pi.on("session_shutdown", () => { stop(); });

  pi.registerCommand("agent-talk", {
    description: "Automatic inbox: on [membership.json], off, or status",
    handler: async (args, ctx) => {
      const input = args.trim();
      if (/[\r\n]/.test(input)) {
        if (ctx.hasUI) ctx.ui.notify("Run one command at a time; the membership path was not changed.", "warning");
        return;
      }
      const match = (input || "status").match(/^(on|off|status)(?:[ \t]+(.+))?$/);
      if (!match || (match[1] !== "on" && match[2])) {
        if (ctx.hasUI) ctx.ui.notify("Use /agent-talk on [membership.json], off, or status.", "warning");
        return;
      }
      if (match[1] === "status") {
        if (ctx.hasUI) ctx.ui.notify([statusMessage, settings?.file,
          "Last successful check: " + (watcher?.lastCheck ?? "none"),
          "Last turn requested: " + (watcher?.lastWake ?? "none")].filter(Boolean).join("\n"), "info");
        return;
      }
      if (match[1] === "off") {
        stop();
        statusMessage = offStatus;
        if (settings) {
          settings = { ...settings, enabled: false };
          pi.appendEntry(settingsType, settings);
        }
        if (ctx.hasUI) ctx.ui.setStatus("agent-talk", statusMessage);
        return;
      }
      const file = match[2] ?? settings?.file;
      if (!validFile(file)) {
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
