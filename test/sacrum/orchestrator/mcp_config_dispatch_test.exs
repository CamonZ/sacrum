defmodule Sacrum.Orchestrator.McpConfigDispatchTest do
  @moduledoc """
  An `llm_inference` step's `agent_config` MCP settings reach the daemon
  unchanged: they are recorded in the execution config and sent in `run_step`.
  A stored MCP config that no longer validates fails the dispatch before an
  execution or command exists, without logging credential values.
  """

  use Sacrum.DataCase, async: false

  import ExUnit.CaptureLog

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, PromptRenderer}
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}

  @secret "sk-live-do-not-echo"

  @agent_config %{
    "provider" => "anthropic",
    "model" => "claude-opus-5-5",
    "strict_mcp_config" => true,
    "allowed_tools" => ["mcp__gate__lookup"],
    "mcp_config" => [
      "/etc/vertebrae/mcp/docs.json",
      %{
        "mcpServers" => %{
          "gate" => %{
            "command" => "gate-mcp",
            "args" => ["--stdio"],
            "env" => %{"GATE_TOKEN" => "${GATE_TOKEN}"}
          }
        }
      }
    ]
  }

  setup do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "mcp-config@example.com",
        username: "mcp_config",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "MCP Config"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "MCP Config"})

    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "restricted",
        step_type: "llm_inference",
        harness: "claude",
        config: %{"prompt" => "Look up {{ task.title }}", "agent_config" => @agent_config}
      })

    step = Repo.preload(step, :workflow)
    {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})
    {:ok, daemon, bootstrap} = Repo.Daemons.create(user.id)
    {:ok, _, _, _} = Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Policy",
        level: "task",
        workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/mcp-config"}
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task = PromptRenderer.preload_for_rendering(task)
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{daemon.id}")
    {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

    %{task: task, step: step, task_run: task_run}
  end

  test "the rendered execution config and run_step payload carry the MCP config verbatim", ctx do
    assert {:ok, execution} =
             ExecutionDispatcher.create_and_dispatch(ctx.task, ctx.step, ctx.task_run)

    assert execution.config.prompt == "Look up Policy"
    assert execution.config.agent_config == @agent_config
    assert Repo.get!(StepExecution, execution.id).config.agent_config == @agent_config

    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
    assert payload.agent_config == @agent_config
    assert payload.harness == "claude"

    # The channel serializes the payload as JSON; the MCP config survives it intact.
    assert payload |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("agent_config") ==
             @agent_config
  end

  test "a stored MCP config that fails validation stops the dispatch without leaking values",
       ctx do
    stale =
      put_in(
        @agent_config,
        ["mcp_config", Access.at(1), "mcpServers", "gate", "env", "GATE_TOKEN"],
        @secret
      )

    # Simulates a row written before MCP config validation existed.
    step = %{ctx.step | config: %{ctx.step.config | agent_config: stale}}

    log =
      capture_log(fn ->
        assert {:error,
                {:config_render_failed,
                 %{
                   code: :mcp_config_invalid,
                   path: "$.agent_config.mcp_config[1].mcpServers.gate.env.GATE_TOKEN",
                   message: message
                 }}} = ExecutionDispatcher.create_and_dispatch(ctx.task, step, ctx.task_run)

        assert message =~ "must reference a daemon environment variable"
      end)

    assert log =~ "mcp_config_invalid"
    refute log =~ @secret
    assert Repo.get_by(StepExecution, task_run_id: ctx.task_run.id) == nil
    assert Repo.get!(TaskRun, ctx.task_run.id).status == :failed
    refute inspect(Repo.get!(TaskRun, ctx.task_run.id)) =~ @secret
    refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}
  end
end
