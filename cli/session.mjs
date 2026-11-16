import { mkdir, open, rm } from "node:fs/promises";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { piArguments } from "./pi.mjs";
import { claudeArguments } from "./claude.mjs";
import { ClientError } from "../integrations/polling/mcp.mjs";
import { stateDir, loadProject, labels, agentClient, connect, provision } from "./project.mjs";

export async function acquireSession(root, config, label) {
  await mkdir(stateDir(root, config), { recursive: true, mode: 0o700 });
  const file = join(stateDir(root, config), label + ".session.lock");
  let handle;
  try { handle = await open(file, "wx", 0o600); }
  catch { throw new ClientError("configuration", "Session already owned or stale lock at " + file + ". Stop the previous session before removing this lock."); }
  try { await handle.writeFile(JSON.stringify({ pid: process.pid }) + "\n"); }
  catch (e) { await handle.close(); await rm(file, { force: true }); throw e; }
  return async () => { await handle.close(); await rm(file, { force: true }); };
}

export async function startAgent(root, label) {
  const config = await loadProject(root);
  if (!labels(config).includes(label)) throw new ClientError("configuration", "Unknown agent label. Add it with add <label> [--client pi|claude] first.");
  const release = await acquireSession(root, config, label);
  try {
    const client = await connect(config.server);
    const result = await provision(root, config, label, client);
    const kind = agentClient(config, label);
    const args = kind === "claude" ? await claudeArguments({ ...result, server: config.server, label }) : piArguments(result.file, config.server);
    console.log(`Starting ${config.project} / ${label}: ${result.member.node_id}, ${result.member.ring_id}`);
    if (kind === "claude") console.log("Claude inbox checks run at session start and prompt submission; idle sessions are not automatically awakened.");
    const child = spawn(kind, args, { cwd: root, stdio: "inherit" });
    const term = () => child.kill("SIGTERM");
    const interrupt = () => child.kill("SIGINT");
    process.once("SIGTERM", term);
    process.once("SIGINT", interrupt);
    try {
      return await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", (code) => resolve(code ?? 1)); });
    } finally {
      process.removeListener("SIGTERM", term);
      process.removeListener("SIGINT", interrupt);
    }
  } finally { await release(); }
}
