#!/usr/bin/env node
import { parseArgs } from "node:util";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { initProject, loadProject, connect, provision } from "./project.mjs";
import { piArguments } from "./pi.mjs";

const help = "Draft: agent-talk init [--client pi] [--workers 4]\n       agent-talk start pm|w-1|w-2|w-3|w-4\nRun from your project root. Only the requested session is launched. Project instructions are owned by your client setup.";
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
try {
  const { values, positionals } = parseArgs({ allowPositionals: true, strict: true, options: {
    client: { type: "string" }, workers: { type: "string" }, server: { type: "string" },
    help: { type: "boolean", short: "h" },
  } });
  const [command, label] = positionals, root = process.cwd();
  if (values.help || !command) console.log(help);
  else if (command === "init" && positionals.length === 1) {
    const config = await initProject(root, values);
    console.log(`Configured ${config.project}. Run each command in its own terminal, PM first:`);
    for (const label of ["pm", ...Array.from({ length: config.workers }, (_, n) => "w-" + (n + 1))]) {
      console.log(`cd ${quote(root)} && ${quote(process.execPath)} ${quote(fileURLToPath(import.meta.url))} start ${label}`);
    }
  } else if (command === "start" && positionals.length === 2 && Object.keys(values).length === 0) {
    const config = await loadProject(root), client = await connect(config.server);
    const { member, file } = await provision(root, config, label, client);
    console.log(`Starting ${config.project} / ${label}: ${member.node_id}, ${member.ring_id}`);
    const child = spawn("pi", piArguments(file, config.server), { cwd: root, stdio: "inherit" });
    const forward = () => child.kill("SIGTERM");
    process.once("SIGTERM", forward);
    process.exitCode = await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", (code) => resolve(code ?? 1)); });
    process.removeListener("SIGTERM", forward);
  } else throw new Error("usage");
} catch (e) {
  console.error(e.code === "transport" ? "AgentTalk is unavailable; check the configured server and rerun." :
    e.code === "configuration" || ["expired", "token", "tool", "protocol", "session"].includes(e.code) ?
    e.message : "AgentTalk command failed. Check the configuration and Pi installation.\n" + help);
  process.exitCode = 1;
}
