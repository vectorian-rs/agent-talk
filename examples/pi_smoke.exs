# mix run --no-start examples/pi_smoke.exs [path-to-pi]
# Isolated broker and three real Pi processes; no trial-server access or paid model.
if Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_talk)) do
  raise "Run with mix run --no-start"
end

Application.put_env(:agent_talk, :http_enabled, false)
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:agent_talk)

{:ok, listener} =
  Bandit.start_link(plug: AgentTalk.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

{:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
script = Path.expand("../integrations/pi/smoke.mjs", __DIR__)

case System.cmd("node", [script, "http://127.0.0.1:#{port}/mcp" | System.argv()],
       stderr_to_stdout: true
     ) do
  {output, 0} -> IO.write(output)
  {output, _} -> raise String.trim(output)
end
