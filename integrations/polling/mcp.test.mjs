import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { McpClient, readMembership } from "./mcp.mjs";

function transport(handler) {
  const calls = [];
  return {
    calls,
    fetch: async (_url, options) => {
      const body = JSON.parse(options.body);
      calls.push({ ...body, headers: options.headers });
      if (body.method === "initialize") {
        return Response.json({ id: body.id, result: { protocolVersion: "2025-11-25" } },
          { headers: { "mcp-session-id": "transport-session" } });
      }
      if (body.method === "notifications/initialized") return new Response(null, { status: 202 });
      return handler(body);
    },
  };
}

test("invalid MCP URLs fail without echoing credentials", () => {
  for (const url of ["not a URL test-only-secret", "http://user:test-only-secret@localhost/mcp", "file:///private"]) {
    assert.throws(() => new McpClient(url), (error) =>
      error.code === "configuration" && !error.message.includes("test-only-secret"));
  }
});

test("initializes Streamable HTTP once and sends session and protocol headers", async () => {
  const fake = transport((body) =>
    Response.json({ id: body.id, result: { structuredContent: { nodes: [] } } }));
  const client = new McpClient("http://127.0.0.1/mcp", fake);
  assert.deepEqual(await client.call("list_nodes", {}), { nodes: [] });
  await client.call("list_nodes", {});
  assert.deepEqual(fake.calls.map((call) => call.method),
    ["initialize", "notifications/initialized", "tools/call", "tools/call"]);
  assert.equal(fake.calls.at(-1).headers["mcp-session-id"], "transport-session");
  assert.equal(fake.calls.at(-1).headers["mcp-protocol-version"], "2025-11-25");
});

test("reads streamed SSE with split CRLF delimiters and unrelated events", async () => {
  const fake = transport((body) => {
    const data = ': keepalive\r\n\r\ndata: {"method":"notification"}\r\n\r\ndata: ' +
      JSON.stringify({ id: body.id, result: { structuredContent: { okay: true } } }) + "\r\n\r\n";
    const bytes = new TextEncoder().encode(data);
    return new Response(new ReadableStream({
      start(controller) {
        for (const byte of bytes) controller.enqueue(new Uint8Array([byte]));
        controller.close();
      },
    }), { headers: { "content-type": "text/event-stream" } });
  });
  assert.deepEqual(await new McpClient("http://127.0.0.1/mcp", fake).call("list_nodes", {}),
    { okay: true });
});

test("expired transport session reconnects; a network failure does not replay a send", async () => {
  let attempts = 0;
  const fake = transport((body) => ++attempts === 1 ?
    new Response(null, { status: 404 }) :
    Response.json({ id: body.id, result: { structuredContent: {} } }));
  await new McpClient("http://127.0.0.1/mcp", fake).call("list_nodes", {});
  assert.equal(fake.calls.filter((call) => call.method === "initialize").length, 2);

  const broken = transport(() => { throw new Error("Raw server data must stay private"); });
  await assert.rejects(new McpClient("http://127.0.0.1/mcp", broken).call("communicate",
    { action: "send" }), (error) => error.code === "transport" &&
      !error.message.includes("Raw server"));
  assert.equal(broken.calls.filter((call) => call.method === "tools/call").length, 1);
});

test("tool authentication errors are classified without echoing response bodies", async () => {
  const fake = transport((body) => Response.json({ id: body.id, result: {
    isError: true, content: [{ type: "text", text: "invalid node token: test-only-secret" }],
  } }));
  await assert.rejects(new McpClient("http://127.0.0.1/mcp", fake).call("list_nodes", {}),
    (error) => error.code === "token" && !error.message.includes("test-only-secret"));
});

test("credentials are read privately, missing files wait, malformed registrations are rejected", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-talk-membership-"));
  const file = join(directory, "worker.json");
  try {
    assert.equal(await readMembership(file), null);
    await writeFile(file, "null", { mode: 0o600 });
    await assert.rejects(readMembership(file), (error) => error.code === "configuration");
    await writeFile(file, JSON.stringify({ node_id: "n", token: "test-only", role: "worker", ring_id: "r" }));
    assert.equal((await readMembership(file)).node_id, "n");
  } finally {
    await rm(directory, { recursive: true });
  }
});

test("reads the complete MCP registration result saved by Pi", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-talk-pi-registration-"));
  const file = join(directory, "worker.json");
  const member = {
    node_id: "node-test", ring_id: "ring-test", role: "worker",
    token: "test-only-private", ring_token: "test-only-invitation",
    expires_in_seconds: 86400, instructions: "Test instructions",
  };
  try {
    const result = { content: [{ type: "text", text: JSON.stringify(member) }],
      isError: false, structuredContent: member };
    await writeFile(file, JSON.stringify(result), { mode: 0o600 });
    const saved = await readMembership(file);
    assert.equal(saved.node_id, member.node_id);
    assert.equal(saved.ring_id, member.ring_id);
    assert.ok(saved.token === member.token && saved.ring_token === member.ring_token,
      "Reading the MCP result must preserve registration credentials");
    assert.equal(saved.instructions, member.instructions);

    await writeFile(file, JSON.stringify({ ...result, isError: true }));
    await assert.rejects(readMembership(file), (error) => error.code === "configuration" &&
      !error.message.includes(member.token));
    await writeFile(file, JSON.stringify({ ...result, structuredContent: null }));
    await assert.rejects(readMembership(file), (error) => error.code === "configuration");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
