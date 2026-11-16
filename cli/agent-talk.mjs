#!/usr/bin/env node
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { initProject, loadProject, connect, inbox, inboxServer, labels, addAgent } from "./project.mjs";
import { startAgent } from "./session.mjs";
import { ClientError, McpClient } from "../integrations/polling/mcp.mjs";

const help = "Draft: agent-talk init [--client pi|claude] [--workers 4] [--team NAME]\n       agent-talk add <label> [--client pi|claude]\n       agent-talk start <label>\n       agent-talk inbox <membership.json> [--server URL]\nRun from your project root. Add configures a worker in the existing team, never creates a ring. Only start launches a session. Project instructions remain owned by your client setup.";
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
try {
  const { values, positionals } = parseArgs({ allowPositionals: true, strict: true, options: {
    client: { type: "string" }, workers: { type: "string" }, server: { type: "string" }, team: { type: "string" },
    help: { type: "boolean", short: "h" },
  } });
  const [command, label] = positionals, root = process.cwd();
  if (values.help || !command) console.log(help);
  else if (command === "init" && positionals.length === 1) {
    const config = await initProject(root, values);
    console.log(`Configured ${config.project}. Run each command in its own terminal, PM first:`);
    for (const label of labels(config)) {
      console.log(`cd ${quote(root)} && ${quote(process.execPath)} ${quote(fileURLToPath(import.meta.url))} start ${label}`);
    }
  } else if (command === "add" && positionals.length === 2 && Object.keys(values).every((key) => key === "client")) {
    const config = await loadProject(root), client = await connect(config.server);
    await addAgent(root, label, values, client);
    console.log(`Configured ${label} in team ${config.team}. Start it in its own terminal:`);
    console.log(`cd ${quote(root)} && ${quote(process.execPath)} ${quote(fileURLToPath(import.meta.url))} start ${label}`);
  } else if (command === "start" && positionals.length === 2 && Object.keys(values).length === 0) {
    process.exitCode = await startAgent(root, label);
  } else if (command === "inbox" && positionals.length === 2 &&
             Object.keys(values).every((key) => key === "server")) {
    const client = new McpClient(await inboxServer(root, values));
    const { node_id, pending, next } = await inbox(label, client);
    console.log(pending > 0 ?
      `AgentTalk: ${pending} pending message(s) for ${node_id} (next ${next}). Call communicate(action="receive") to read them.` :
      `AgentTalk: inbox empty for ${node_id}.`);
  } else throw new Error("usage");
} catch (e) {
  // ClientError messages are credential-free by design (see mcp.mjs); print them as-is.
  console.error(e.code === "transport" ? "AgentTalk is unavailable; check the configured server and rerun." :
    e instanceof ClientError ? e.message :
    "AgentTalk command failed. Check the configuration and selected client installation.\n" + help);
  process.exitCode = 1;
}
