#!/bin/sh
# Run after mix deps.get, before compiling Anubis MCP.
set -eu
cd "$(dirname "$0")/.."
patch=patches/anubis_mcp-sse-read-timeout.patch
if git apply --reverse --check --directory=deps/anubis_mcp "$patch" 2>/dev/null; then
  echo 'Anubis SSE timeout patch already applied.'
else
  git apply --check --directory=deps/anubis_mcp "$patch"
  git apply --directory=deps/anubis_mcp "$patch"
  echo 'Applied Anubis SSE timeout patch.'
fi
