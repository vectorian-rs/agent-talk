import { access, open, rm } from "node:fs/promises";
import { basename, join } from "node:path";
import { ClientError, validateServerUrl } from "../integrations/polling/mcp.mjs";
import { connect, provision } from "./project.mjs";
import { claudeArguments } from "./claude.mjs";
import { piArguments } from "./pi.mjs";

const error = (message) => new ClientError("configuration", message);
const safeName = (value) => typeof value === "string" && /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(value);
const exists = async (file) => access(file).then(() => true, (e) => { if (e.code === "ENOENT") return false; throw e; });
export const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
export const launchCommand = (root, launch) => `cd ${shellQuote(root)} && ${launch.client} ${launch.args.map(shellQuote).join(" ")}`;

// Explicit team, label and client. No roster, discovery, numbering or new ring.
export async function allocateAgent(root, label, options = {}, connection = connect) {
  if (!safeName(label) || ["pm", "invitation"].includes(label)) throw error("Choose an unused worker label; pm and invitation are reserved.");
  if (!safeName(options.team)) throw error("Specify the existing team with --team NAME.");
  if (!["pi", "claude"].includes(options.client)) throw error("Specify --client pi or --client claude.");
  const server = options.server ?? "http://127.0.0.1:4000/mcp";
  validateServerUrl(server);
  const directory = join(root, ".agent-talk", options.team);
  if (!await exists(join(directory, "pm.json")) && !await exists(join(directory, "invitation.json"))) {
    throw error("The team needs a saved pm.json or invitation.json. Add never creates a ring.");
  }
  const project = basename(root);
  if (!project.trim() || project.length > 122 || /[\u0000-\u001f\u007f-\u009f]/u.test(project)) throw error("Project directory name is not a valid display label.");
  const lockFile = join(directory, "allocation.lock");
  let lock;
  try { lock = await open(lockFile, "wx", 0o600); }
  catch { throw error("Another allocation is in progress. If it exited, remove the team's allocation.lock and retry."); }
  try {
    if (await exists(join(directory, label + ".json"))) throw error("That label already has a membership. Choose an unused label; add will not take over an existing agent.");
    const client = await connection(server);
    const config = { server, project, team: options.team, client: options.client, label };
    const result = await provision(root, config, label, client);
    const args = options.client === "claude" ? await claudeArguments({ ...result, server, label }) : piArguments(result.file, server);
    return { client: options.client, label, args };
  } finally { await lock.close(); await rm(lockFile, { force: true }); }
}
