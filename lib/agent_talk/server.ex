defmodule AgentTalk.Server do
  @moduledoc false
  use Anubis.Server,
    name: "agent-talk",
    version: "0.2.0",
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
    use action=receive between tasks to drain your inbox. This server does not
    start or wake agents; do not run endless agent polling.
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
