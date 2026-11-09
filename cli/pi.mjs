import { fileURLToPath } from "node:url";

export function piArguments(file, server) {
  return ["-e", fileURLToPath(new URL("../integrations/pi/agent-talk.ts", import.meta.url)),
    "--agent-talk-membership", file, "--agent-talk-url", server];
}
