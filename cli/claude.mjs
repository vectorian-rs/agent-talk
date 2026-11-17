import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { savePrivate } from "./project.mjs";

const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";

// Session-local files keep the membership binding out of shared Claude settings.
// No bearer credentials enter settings, prompts or launch arguments.
export async function claudeArguments({ file, server, label, pmId }) {
  const directory = file + ".claude";
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const mcp = join(directory, "mcp.json");
  const settings = join(directory, "settings.json");
  const instructions = join(directory, "transport.json");
  const cli = fileURLToPath(new URL("./agent-talk.mjs", import.meta.url));
  const command = [process.execPath, cli, "inbox", file, "--server", server].map(quote).join(" ");
  const hook = [{ hooks: [{ type: "command", command }] }];
  await savePrivate(mcp, { mcpServers: { "agent-talk": { type: "http", url: server } } });
  await savePrivate(settings, { hooks: { SessionStart: hook, UserPromptSubmit: hook } });
  await savePrivate(instructions, {
    membership_file: file,
    label,
    pm_id: pmId ?? null,
    instructions: [
      "This is an AgentTalk transport binding, not a project workflow. Follow the repository's existing instructions and approval rules.",
      "The launcher has already registered or renewed this session. Read only your membership file for credentials; do not register a new ring or use another agent's credentials.",
      "Keep node and ring tokens out of output, logs and commits. If you renew or rejoin, save each complete successful registration atomically with mode 0600 before another authenticated call.",
      "Call list_nodes with your saved node_id and token; verify the returned ring_id matches your saved membership.",
      ...(pmId ? [`Verify ${pmId} is an active PM in your ring, then send it 'joined ${label}' with communicate. If it cannot be verified, ask the operator; do not guess a replacement.`] : []),
      "When the inbox hook reports pending mail, call communicate(action=receive) using your own credentials. Verify senders and assignments. Reply only with the protocol lines your project instructions define; send no receipts or acknowledgments.",
      "Hooks check metadata only at session start and prompt submission. They do not wake an idle session. Do not run empty model polling loops.",
      "If credentials expire, rejoin only the saved ring using the saved role and ring_token, save the complete response, rediscover peers and notify the verified PM of your changed identity. Invalid tokens require the operator.",
    ],
  });
  return ["--name", label, "--mcp-config", mcp, "--settings", settings,
    "--append-system-prompt", "Read and follow the AgentTalk transport binding at " + JSON.stringify(instructions) + ".",
    "Initialize the configured AgentTalk transport and check your inbox. Do not change project files during onboarding."];
}
