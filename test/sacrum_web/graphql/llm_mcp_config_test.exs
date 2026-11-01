defmodule SacrumWeb.Graphql.LlmMcpConfigTest do
  @moduledoc """
  GraphQL contract for `llm_inference` `agent_config.mcp_config`: inline MCP
  JSON, daemon paths, strict mode and legacy configs round-trip through
  create, read and update unchanged, and invalid configs fail with path-only
  errors.
  """

  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  @fields """
  id
  config { ... on LlmInferenceStepConfig { agentConfig } }
  """

  @secret "sk-live-do-not-echo"

  @inline %{
    "mcpServers" => %{
      "gate" => %{
        "command" => "gate-mcp",
        "args" => ["--stdio"],
        "env" => %{"GATE_TOKEN" => "${GATE_TOKEN}"}
      }
    }
  }

  @strict_inline %{
    "provider" => "anthropic",
    "model" => "claude-opus-5-5",
    "mcp_config" => [@inline],
    "strict_mcp_config" => true,
    "allowed_tools" => ["mcp__gate__lookup"]
  }

  @daemon_path %{"mcp_config" => ["~/.config/vertebrae/mcp/gate.json"]}
  @mixed %{"mcp_config" => ["/etc/vertebrae/mcp.json", @inline], "strict_mcp_config" => false}
  @strict_empty %{"mcp_config" => [], "strict_mcp_config" => true}
  @legacy %{"model" => "opus", "tools" => [], "allowed_tools" => ["Read"]}

  setup do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "MCP Project"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "MCP"})
    %{user: user, workflow: workflow}
  end

  defp create({conn, user}, workflow, agent_config) do
    conn
    |> recycle()
    |> authenticate(user)
    |> graphql("""
    mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "mcp", stepType: "llm_inference", harness: "claude", config: #{json_arg(%{"prompt" => "Go", "agent_config" => agent_config})}) { #{@fields} } }
    """)
    |> json_response(200)
  end

  defp read({conn, user}, id) do
    conn
    |> recycle()
    |> authenticate(user)
    |> graphql("query { workflowStep(id: \"#{id}\") { #{@fields} } }")
    |> json_response(200)
  end

  defp update({conn, user}, id, agent_config) do
    conn
    |> recycle()
    |> authenticate(user)
    |> graphql("""
    mutation { updateWorkflowStep(id: "#{id}", config: #{json_arg(%{"agent_config" => agent_config})}) { #{@fields} } }
    """)
    |> json_response(200)
  end

  test "create and read preserve inline, daemon-path, strict, omitted and legacy configs",
       %{conn: conn, user: user, workflow: workflow} do
    for agent_config <- [@strict_inline, @daemon_path, @mixed, @strict_empty, %{}, @legacy] do
      created = create({conn, user}, workflow, agent_config)
      refute created["errors"], inspect(created["errors"])
      step = created["data"]["createWorkflowStep"]

      assert step["config"]["agentConfig"] == agent_config
      assert read({conn, user}, step["id"])["data"]["workflowStep"] == step
    end
  end

  test "update replaces the MCP config", %{conn: conn, user: user, workflow: workflow} do
    id = create({conn, user}, workflow, @legacy)["data"]["createWorkflowStep"]["id"]

    for agent_config <- [@strict_inline, @strict_empty, @legacy] do
      updated = update({conn, user}, id, agent_config)
      refute updated["errors"], inspect(updated["errors"])
      assert updated["data"]["updateWorkflowStep"]["config"]["agentConfig"] == agent_config

      assert read({conn, user}, id)["data"]["workflowStep"]["config"]["agentConfig"] ==
               agent_config
    end
  end

  test "invalid MCP configs are rejected with the path and no submitted values",
       %{conn: conn, user: user, workflow: workflow} do
    leaky =
      put_in(
        @strict_inline,
        ["mcp_config", Access.at(0), "mcpServers", "gate", "env", "GATE_TOKEN"],
        @secret
      )

    for {agent_config, message} <- [
          {leaky,
           "config.agent_config: $.agent_config.mcp_config[0].mcpServers.gate.env.GATE_TOKEN: " <>
             "must reference a daemon environment variable such as ${API_TOKEN}; " <>
             "literal values are not stored in workflow config"},
          {%{"mcp_config" => [".mcp.json"]},
           "config.agent_config: $.agent_config.mcp_config[0]: " <>
             "must be an absolute daemon-local path (starting with / or ~/)"},
          {%{"strict_mcp_config" => "yes"},
           "config.agent_config: $.agent_config.strict_mcp_config: must be true or false"}
        ] do
      result = create({conn, user}, workflow, agent_config)

      assert [%{"message" => ^message, "code" => "mcp_config_invalid"}] = result["errors"]
      refute inspect(result) =~ @secret
    end

    id = create({conn, user}, workflow, @strict_inline)["data"]["createWorkflowStep"]["id"]

    assert [%{"message" => message, "code" => "mcp_config_invalid"}] =
             update({conn, user}, id, leaky)["errors"]

    assert message =~ "GATE_TOKEN: must reference a daemon environment variable"

    assert read({conn, user}, id)["data"]["workflowStep"]["config"]["agentConfig"] ==
             @strict_inline
  end

  test "bundle import rejects an invalid MCP config with its code and no submitted values",
       %{conn: conn, user: user} do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "MCP Bundle"})

    bundle = %{
      "workflows" => [
        %{
          "workflow_ref" => "mcp",
          "name" => "MCP",
          "steps" => [
            %{
              "step_ref" => "restricted",
              "name" => "Restricted",
              "step_type" => "llm_inference",
              "harness" => "claude",
              "config" => %{
                "prompt" => "Go",
                "agent_config" => %{
                  "mcp_config" => [
                    %{
                      "mcpServers" => %{
                        "gate" => %{"command" => "gate-mcp", "env" => %{"T" => @secret}}
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
      ]
    }

    result =
      conn
      |> authenticate(user)
      |> graphql("""
      mutation { importWorkflowBundle(projectId: "#{project.id}", bundle: #{json_arg(bundle)}) { workflowCount } }
      """)
      |> json_response(200)

    assert [%{"code" => "mcp_config_invalid", "message" => message}] = result["errors"]

    assert message =~
             "workflows[0].steps[0].config.agent_config.mcp_config[0].mcpServers.gate.env.T"

    refute inspect(result) =~ @secret
  end

  defp graphql(conn, query), do: post(conn, "/graphql", %{"query" => query})

  defp json_arg(value), do: Jason.encode!(Jason.encode!(value))
end
