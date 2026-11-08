// Test-only deterministic model. No provider network requests or real API keys.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFile, writeFile } from "node:fs/promises";
import { McpClient, readMembership } from "../../polling/mcp.mjs";

export default function smokeProvider(pi: ExtensionAPI) {
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
      const tool = context.messages.at(-1)?.role !== "toolResult";
      const message = {
        role: "assistant", api: model.api, provider: model.provider, model: model.id,
        content: tool ? [{ type: "toolCall", id: "smoke-" + Date.now(),
          name: "smoke_mail", arguments: {} }] : [{ type: "text", text: "Handled." }],
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
    parameters: Type.Object({}),
    async execute(_id, _params, _signal, _update, ctx) {
      const settings = ctx.sessionManager.getBranch().findLast((entry) =>
        entry.type === "custom" && entry.customType === "agent-talk-inbox-settings").data;
      const file = settings.file;
      const member = await readMembership(file);
      const client = new McpClient(settings.url);
      const auth = { node_id: member.node_id, token: member.token };
      const result = await client.call("communicate", { ...auth, action: "receive" });
      if (member.role === "worker") {
        for (const message of result.messages) {
          await client.call("communicate", { ...auth, action: "send",
            to: [message.from], message: "done: smoke" });
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
