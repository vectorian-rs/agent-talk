defmodule AgentTalk.Server do
  @moduledoc false
  use Anubis.Server,
    name: "agent-talk",
    version: Mix.Project.config()[:version],
    capabilities: [:tools],
    instructions: """
    A PM calls register_node with role=pm to create a ring. Save the response and
    use its ring_token and onboarding_prompt_template to invite other agents.
    Invited agents call register_node with their role and ring_token. Roles such
    as worker or reviewer are supplied by the agent; IDs are assigned by the server.
    Save every successful registration response privately before another call,
    and follow its instructions. Ring tokens invite members; private node tokens
    authenticate individual agents. Never share a private node token.
    Use node_id and your private token with list_nodes and communicate. Discovery
    and delivery are restricted to your ring. Send to discovered IDs or to_role;
    use action=receive when notified or between tasks to drain your inbox. An optional
    host integration polls list_nodes.inbox and wakes the session when mail arrives.
    Without an integration, the operator resumes idle agents. This server does not
    start agents; do not use LLM turns for empty polling.
    Authenticated discovery, communication and renewal reset your lease (24 hours
    by default; use the returned duration). Renew with role, node_id and token.
    Expiry discards your inbox. Rejoin the same ring with role and ring_token for
    a new ID/token, save the response, and reconcile work with the project record.
    Fresh role-only PM registration creates another ring, not a resumed session.
    """

  component(AgentTalk.Tools.ListNodes)
  component(AgentTalk.Tools.RegisterNode)
  component(AgentTalk.Tools.Communicate)
end
