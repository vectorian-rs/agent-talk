// Test-only deterministic model. No provider network requests or real API keys.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFile, writeFile, rename, access, rm } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { readMembership } from "../../polling/mcp.mjs";

export default function smokeProvider(pi: ExtensionAPI) {
  pi.registerFlag("agent-talk-smoke-role", { type: "string", description: "Test role" });
  pi.registerFlag("agent-talk-smoke-invitation", { type: "string", description: "Test invitation file" });
  pi.registerCommand("smoke-reload", {
    description: "Test-only extension reload",
    handler: async (_args, ctx) => { await ctx.reload(); },
  });
  pi.registerCommand("smoke-bad-binding", {
    description: "Test-only legacy path corruption",
    handler: async (_args, ctx) => {
      const prior = ctx.sessionManager.getBranch().findLast((entry) =>
        entry.type === "custom" && entry.customType === "agent-talk-inbox-settings").data;
      pi.appendEntry("agent-talk-inbox-settings", { ...prior, file: "/agent-talk status" });
    },
  });

  pi.on("before_agent_start", async () => {
    const deadline = Date.now() + 10_000;
    while (!pi.getAllTools().some((tool) => tool.name === "mcp__agent_talk__register_node")) {
      if (Date.now() >= deadline) throw new Error("Smoke MCP tools did not connect");
      await delay(50);
    }
  });

  async function call(ctx, name, args, signal) {
    const response = await ctx.executeTool("mcp__agent_talk__" + name, args, { signal });
    const result = response.result.structuredContent;
    if (response.isError || result?.isError || !result?.structuredContent) {
      throw new Error("Smoke " + name + " failed; response omitted");
    }
    return result;
  }

  pi.registerProvider("agent-talk-smoke", {
    api: "agent-talk-smoke",
    baseUrl: "http://127.0.0.1:1",
    apiKey: "local-test-placeholder",
    models: [{
      id: "smoke", name: "Local AgentTalk smoke test", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 100_000, maxTokens: 1024,
    }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const last = context.messages.at(-1);
      const tool = last?.role !== "toolResult";
      const text = typeof last?.content === "string" ? last.content :
        last?.content?.filter((part) => part.type === "text").map((part) => part.text).join("");
      const message = {
        role: "assistant", api: model.api, provider: model.provider, model: model.id,
        content: tool ? [{ type: "toolCall", id: "smoke-" + Date.now(),
          name: "smoke_mail", arguments: { action: ({ "assign smoke": "assign", "hold smoke": "hold",
            "resume smoke": "noop" })[text] ?? "inbox" } }] :
          [{ type: "text", text: "Handled." }],
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: tool ? "toolUse" : "stop", timestamp: Date.now(),
      };
      queueMicrotask(() => {
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason: message.stopReason, message });
        stream.end();
      });
      return stream;
    },
  });
  pi.registerTool({
    name: "smoke_mail", label: "Smoke inbox", description: "Test-only inbox handler",
    parameters: Type.Object({ action: Type.Union(["assign", "inbox", "hold", "noop"].map((action) => Type.Literal(action))) }),
    async execute(_id, params, signal, _update, ctx) {
      const settings = ctx.sessionManager.getBranch().findLast((entry) =>
        entry.type === "custom" && entry.customType === "agent-talk-inbox-settings").data;
      const file = settings.file;
      if (params.action === "noop") return { content: [{ type: "text", text: "Ready" }], details: {} };
      if (params.action === "hold") {
        await writeFile(file + ".busy", "1", { mode: 0o600 });
        while (!signal?.aborted) {
          if (await access(file + ".release").then(() => true, () => false)) break;
          await delay(25);
        }
        await rm(file + ".busy", { force: true });
        await rm(file + ".release", { force: true });
        return { content: [{ type: "text", text: "Hold ended" }], details: {} };
      }
      const member = await readMembership(file);
      if (!member) {
        const role = String(pi.getFlag("agent-talk-smoke-role"));
        const args = { role };
        if (role !== "pm") {
          const invitation = JSON.parse(await readFile(String(pi.getFlag("agent-talk-smoke-invitation")), "utf8"));
          args.ring_token = invitation.ring_token;
        }
        // Save exactly the result Pi exposes, including its MCP envelope.
        const result = await call(ctx, "register_node", args, signal);
        await writeFile(file + ".tmp", JSON.stringify(result), { mode: 0o600 });
        await rename(file + ".tmp", file);
        return { content: [{ type: "text", text: "Registered privately" }], details: {} };
      }
      const auth = { node_id: member.node_id, token: member.token };
      if (params.action === "assign") {
        const found = (await call(ctx, "list_nodes", { ...auth, role: "worker" }, signal)).structuredContent;
        await call(ctx, "communicate", { ...auth, action: "send",
          to: found.nodes.map((node) => node.node_id), message: "pick up smoke" }, signal);
        return { content: [{ type: "text", text: "Assigned" }], details: {} };
      }
      const result = (await call(ctx, "communicate", { ...auth, action: "receive" }, signal)).structuredContent;
      if (member.role === "worker") {
        for (const message of result.messages) {
          await call(ctx, "communicate", { ...auth, action: "send",
            to: [message.from], message: "done: smoke" }, signal);
        }
      }
      const previous = await readFile(file + ".received", "utf8").then(JSON.parse)
        .catch((error) => { if (error.code === "ENOENT") return []; throw error; });
      await writeFile(file + ".received", JSON.stringify([...previous, ...result.messages]),
        { mode: 0o600 });
      return { content: [{ type: "text", text: "Handled " + result.messages.length }], details: {} };
    },
  });
}
