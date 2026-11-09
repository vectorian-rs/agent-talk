import { readFile, writeFile, mkdir, chmod, open, rename, rm } from "node:fs/promises";
import { basename, resolve, join } from "node:path";
import { randomBytes } from "node:crypto";
import { parse, stringify } from "smol-toml";
import { ClientError, McpClient, readMembership } from "../integrations/polling/mcp.mjs";

const keys = ["server", "client", "project", "team", "workers", "pm_prompt", "worker_prompt"];
const error = (message) => new ClientError("configuration", message);

export function validate(config) {
  if (Object.keys(config).some((key) => !keys.includes(key))) throw error("Unknown setting in agent-talk.toml.");
  new McpClient(config.server);
  if (config.client !== "pi") throw error("This draft supports client = pi only.");
  if (typeof config.project !== "string" || !config.project.trim() || config.project.length > 122 || /[\u0000-\u001f\u007f-\u009f]/u.test(config.project)) {
    throw error("project must be a nonempty label of at most 122 characters without control characters.");
  }
  if (typeof config.team !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(config.team)) {
    throw error("team must contain 1..64 letters, digits, underscores or hyphens.");
  }
  if (!Number.isInteger(config.workers) || config.workers < 1 || config.workers > 4) {
    throw error("workers must be 1..4.");
  }
  for (const key of ["pm_prompt", "worker_prompt"]) {
    if (typeof config[key] !== "string" || !config[key].trim()) throw error(key + " must name a role instruction file.");
  }
  return { ...config };
}

export async function loadProject(root) {
  let config;
  try { config = parse(await readFile(join(root, "agent-talk.toml"), "utf8")); }
  catch { throw error("Cannot read agent-talk.toml. Run init from the project root first."); }
  return validate(config);
}

export async function savePrivate(file, value) {
  const temporary = file + "." + randomBytes(12).toString("hex") + ".tmp";
  let handle;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(JSON.stringify(value, null, 2) + "\n");
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, file);
  } catch { throw error("Cannot save private AgentTalk state; no session was launched."); }
  finally { await handle?.close(); await rm(temporary, { force: true }); }
}

async function prepare(root, config) {
  for (const path of [join(root, ".agent-talk"), stateDir(root, config)]) {
    await mkdir(path, { recursive: true, mode: 0o700 });
    await chmod(path, 0o700);
  }
  const ignore = join(root, ".gitignore");
  const prior = await readFile(ignore, "utf8").catch((e) => { if (e.code === "ENOENT") return ""; throw e; });
  if (!prior.split(/\r?\n/).some((line) => ["/.agent-talk/", "**/.agent-talk/", ".agent-talk/"].includes(line.trim()))) {
    await writeFile(ignore, prior + (prior && !prior.endsWith("\n") ? "\n" : "") + "/.agent-talk/\n");
  }
  const file = join(root, ".pi/mcp.json");
  let mcp;
  try { mcp = JSON.parse(await readFile(file, "utf8")); }
  catch (e) { if (e.code !== "ENOENT") throw error("Cannot read .pi/mcp.json; existing configuration was preserved."); mcp = {}; }
  if (!mcp || typeof mcp !== "object" || Array.isArray(mcp) ||
      (mcp.mcpServers !== undefined && (!mcp.mcpServers || typeof mcp.mcpServers !== "object" || Array.isArray(mcp.mcpServers)))) {
    throw error("Invalid .pi/mcp.json; existing configuration was preserved.");
  }
  const desired = { ...mcp, mcpServers: { ...mcp.mcpServers, "agent-talk": { url: config.server, exposure: "direct" } } };
  if (JSON.stringify(mcp) !== JSON.stringify(desired)) {
    await mkdir(join(root, ".pi"), { recursive: true });
    await savePrivate(file, desired);
  }
}

export async function initProject(root, options = {}) {
  const file = join(root, "agent-talk.toml");
  let config;
  try { await readFile(file); config = await loadProject(root); }
  catch (e) {
    if (e.code !== "ENOENT") throw e;
    config = validate({ server: options.server ?? "http://127.0.0.1:4000/mcp", client: options.client ?? "pi",
      project: basename(root), team: "delivery", workers: Number(options.workers ?? 2),
      pm_prompt: options.pm_prompt ?? "AGENTS.md", worker_prompt: options.worker_prompt ?? "AGENTS.md" });
    await checkPrompts(root, config);
    await writeFile(file, stringify(config), { flag: "wx" });
  }
  await checkPrompts(root, config);
  await prepare(root, config);
  return config;
}

async function checkPrompts(root, config) {
  for (const path of new Set([config.pm_prompt, config.worker_prompt])) {
    try { await readFile(resolve(root, path), "utf8"); }
    catch { throw error("Role instructions are missing. Set pm_prompt and worker_prompt to existing files."); }
  }
}

export const stateDir = (root, config) => join(root, ".agent-talk", config.team);
export const memberFile = (root, config, label) => join(stateDir(root, config), label + ".json");

export async function connect(server) {
  const client = new McpClient(server);
  const tools = await client.listTools();
  const registration = tools.find((tool) => tool.name === "register_node")?.inputSchema;
  if (!registration?.properties?.ring_token || !registration.required?.includes("role") ||
      registration.required.includes("node_id") || !["list_nodes", "communicate"].every((name) => tools.some((tool) => tool.name === name))) {
    throw error("The MCP server does not expose the AgentTalk ring API.");
  }
  return client;
}

export async function provision(root, config, label, client) {
  const labels = ["pm", ...Array.from({ length: config.workers }, (_, n) => "w-" + (n + 1))];
  if (!labels.includes(label)) throw error("Choose pm or a configured worker label.");
  await checkPrompts(root, config);
  await prepare(root, config);
  const role = label === "pm" ? "pm" : "worker", file = memberFile(root, config, label);
  let invitation;
  if (role === "worker") {
    try { invitation = JSON.parse(await readFile(join(stateDir(root, config), "invitation.json"), "utf8")); }
    catch { throw error("Start this team's PM before starting workers."); }
    if (!["ring_id", "ring_token", "pm_id"].every((key) => typeof invitation?.[key] === "string" && invitation[key].length > 0)) {
      throw error("Invalid team invitation; resume the PM first.");
    }
  }
  const saved = await readMembership(file);
  if (saved && (saved.role !== role || (invitation && saved.ring_id !== invitation.ring_id))) {
    throw error("Saved membership does not match this role/team. Use a different team directory.");
  }
  const labelsArg = { project: config.project, name: config.project + " / " + label };
  let member;
  if (saved) {
    try { member = await client.call("register_node", { role, node_id: saved.node_id, token: saved.token, ...labelsArg }); }
    catch (e) {
      if (e.code !== "expired") throw e;
      const ringToken = invitation?.ring_token ?? saved.ring_token;
      if (typeof ringToken !== "string" || !ringToken) throw error("Saved membership lacks its invitation. Ask the operator to restore the team invitation.");
      member = await client.call("register_node", { role, ring_token: ringToken, ...labelsArg });
    }
  } else {
    member = await client.call("register_node", { role, ...labelsArg, ...(invitation ? { ring_token: invitation.ring_token } : {}) });
  }
  if (!["node_id", "token", "ring_id", "ring_token"].every((key) => typeof member?.[key] === "string" && member[key].length > 0) || member.role !== role ||
      (invitation && invitation.ring_id !== member.ring_id) || (saved && saved.ring_id !== member.ring_id)) throw error("Invalid registration response; no session was launched.");
  await savePrivate(file, member);
  if (role === "pm") await savePrivate(join(stateDir(root, config), "invitation.json"), {
    ring_id: member.ring_id, ring_token: member.ring_token, pm_id: member.node_id,
  });
  const prompt = [
    `Read AGENTS.md when present and follow ${JSON.stringify(resolve(root, role === "pm" ? config.pm_prompt : config.worker_prompt))}.`,
    `Use transport=agent-talk as ${label}. Your membership is already registered and saved privately at ${JSON.stringify(file)}.`,
    "This path overrides transport documentation defaults. Read credentials privately; never print either token. Do not create another ring.",
    "The Pi extension checks presence and wakes this session. Receive and handle notifications automatically; send actual replies through communicate.",
    "Follow project claims and human approval gates. Do not start other agents or LLM polling loops.",
    role === "pm" ? `The operator launches ${config.workers} workers with this CLI; no invitation prompts are needed. Verify their joined messages, map labels to sender IDs, report ready, and wait for the owner's issue.` :
      `Verify PM ${invitation.pm_id} in ring ${member.ring_id}, send "joined ${label}" to that PM, then handle its authorized assignments with receipt, disposition and result replies.`,
  ].join("\n");
  return { member, file, prompt };
}
