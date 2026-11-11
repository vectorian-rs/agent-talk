import { readFile } from "node:fs/promises";

// Keep errors independent of response bodies: registrations contain credentials.
export class ClientError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export async function readMembership(file) {
  let value;
  try {
    value = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new ClientError("configuration", "Cannot read the saved AgentTalk registration.");
  }
  // Pi's tools return the MCP envelope; other clients expose its registration.
  const member = value && Object.hasOwn(value, "structuredContent") ? value.structuredContent : value;
  if (value?.isError === true || !member || !["node_id", "token", "ring_id", "role"].every((key) =>
    typeof member[key] === "string" && member[key].length > 0)) {
    throw new ClientError("configuration",
      "Save the successful register_node result or its structuredContent object as JSON.");
  }
  return member;
}

export function validateServerUrl(url) {
  let parsed;
  try { parsed = new URL(url); } catch {
    throw new ClientError("configuration", "Use an HTTP(S) MCP URL without embedded credentials.");
  }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw new ClientError("configuration", "Use an HTTP(S) MCP URL without embedded credentials.");
  }
  return parsed.href;
}

export class McpClient {
  constructor(url, { fetch: fetchImpl = globalThis.fetch } = {}) {
    this.url = validateServerUrl(url);
    this.fetch = fetchImpl;
    this.id = 0;
    this.version = "2025-11-25";
    this.ready = false;
  }

  async call(name, args, signal) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await this.connect(signal);
        const result = await this.request("tools/call", { name, arguments: args }, signal);
        if (result.isError) {
          // Branch on the server's machine-readable code; prose matching only
          // remains as a fallback for servers that predate error codes.
          const code = result.structuredContent?.error?.code;
          const text = (result.content ?? []).filter((item) => item.type === "text")
            .map((item) => item.text).join("\n");
          if (code === "expired" || (!code && text.includes("node is not registered or has expired"))) {
            throw new ClientError("expired", "AgentTalk membership expired or the server restarted.");
          }
          if (code === "invalid_token" || (!code && text.includes("invalid node token"))) {
            throw new ClientError("token", "AgentTalk rejected the saved private node token.");
          }
          throw new ClientError("tool", "AgentTalk rejected the request; response omitted.");
        }
        if (!result.structuredContent) {
          throw new ClientError("protocol", "AgentTalk returned no structured tool result.");
        }
        return result.structuredContent;
      } catch (error) {
        if (error.code !== "session" || attempt > 0) throw error;
        // A missing MCP transport session has not dispatched this tool call.
        this.ready = false;
        this.session = undefined;
      }
    }
  }

  async connect(signal) {
    if (this.ready) return;
    const result = await this.request("initialize", {
      protocolVersion: this.version, capabilities: {},
      clientInfo: { name: "agent-talk-client", version: "1" },
    }, signal);
    this.version = result.protocolVersion;
    await this.request("notifications/initialized", undefined, signal, true);
    this.ready = true;
  }

  async listTools(signal) {
    await this.connect(signal);
    const result = await this.request("tools/list", {}, signal);
    if (!Array.isArray(result.tools)) throw new ClientError("protocol", "Invalid MCP tool list.");
    return result.tools;
  }

  async request(method, params, signal, notification = false) {
    const id = notification ? undefined : ++this.id;
    const headers = {
      "content-type": "application/json", accept: "application/json, text/event-stream",
      "mcp-protocol-version": this.version,
    };
    if (this.session) headers["mcp-session-id"] = this.session;
    let response;
    try {
      response = await this.fetch(this.url, {
        method: "POST", headers,
        body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) :
          AbortSignal.timeout(15_000),
        redirect: "error",
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new ClientError(response.status === 404 ? "session" : "transport",
          "AgentTalk HTTP request failed (" + response.status + ").");
      }
      if (response.headers.has("mcp-session-id")) {
        this.session = response.headers.get("mcp-session-id");
      }
      if (notification) {
        await response.body?.cancel();
        return;
      }
      let message;
      if (response.headers.get("content-type")?.includes("text/event-stream")) {
        message = await readEvent(response, id);
      } else {
        message = await response.json();
      }
      if (message.id !== id || message.error || !message.result) {
        throw new ClientError("protocol", "Invalid AgentTalk MCP response; body omitted.");
      }
      return message.result;
    } catch (error) {
      if (error instanceof ClientError) throw error;
      throw new ClientError("transport", "AgentTalk connection failed; retrying automatically.");
    }
  }
}

async function readEvent(response, id) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      buffer += decoder.decode(value, { stream: !done });
      let boundary;
      while ((boundary = /\r?\n\r?\n/.exec(buffer))) {
        const event = buffer.slice(0, boundary.index);
        buffer = buffer.slice(boundary.index + boundary[0].length);
        const data = event.split(/\r?\n/).filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trimStart()).join("\n");
        if (data) {
          const message = JSON.parse(data);
          if (message.id === id) return message;
        }
      }
      if (done) throw new ClientError("protocol", "AgentTalk stream ended without a response.");
    }
  } finally {
    await reader.cancel();
  }
}
