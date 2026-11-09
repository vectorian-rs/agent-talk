# mix run --no-start examples/pi_smoke.exs [path-to-pi]
# Isolated broker and three real Pi processes; no trial-server access or paid model.
if Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_talk)) do
  raise "Run with mix run --no-start"
end

script = Path.expand("../integrations/pi/smoke.mjs", __DIR__)

case System.cmd("node", [script | System.argv()], stderr_to_stdout: true) do
  {output, 0} -> IO.write(output)
  {output, _} -> raise String.trim(output)
end
