defmodule Sacrum.Orchestrator.StructuredInferenceTest do
  @moduledoc """
  End-to-end contract for `structured_inference` steps with a stubbed provider
  harness: resolve `state`, dispatch the request, validate the harness result
  against `fields`, and expose the stored output to the next step.
  """

  use Sacrum.DataCase, async: false

  import Ecto.Query

  alias Sacrum.Accounts

  alias Sacrum.Orchestrator.{
    ExecutionDispatcher,
    StructuredInference,
    TaskFSMSupervisor,
    TaskOrchestrator
  }

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @fields %{
    "type" => "object",
    "properties" => %{
      "approved" => %{
        "type" => "string",
        "enum" => ["yes", "no"],
        "description" => "Is the task ready?"
      }
    },
    "required" => ["approved"],
    "additionalProperties" => false
  }

  @structured_config %{
    "provider" => "typesafe",
    "model" => "jev-latest",
    "state" => %{"title" => "{{ task.title }}", "tags" => "{{ task.tags }}"},
    "fields" => @fields
  }

  defp setup_workflow(structured_config \\ @structured_config) do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "structured_inference@example.com",
        username: "structured_inference",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Structured Project"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Structured"})

    judge =
      create_step(user, workflow, %{
        "name" => "judge",
        "step_order" => 1,
        "step_type" => "structured_inference",
        "config" => structured_config
      })

    consume =
      create_step(user, workflow, %{
        "name" => "consume",
        "step_order" => 2,
        "config" => %{
          "prompt" =>
            "approved={{ execution.previous_output.approved }} " <>
              "p={{ execution.previous_meta.approved.probabilities.yes }} " <>
              "named={{ steps.judge.output.approved }}",
          "agent_config" => %{"model" => "test-model"}
        }
      })

    finish =
      create_step(user, workflow, %{"name" => "done", "step_order" => 3, "step_type" => "finish"})

    for {from, to} <- [{judge, consume}, {consume, finish}] do
      {:ok, _} =
        Accounts.StepTransitions.insert(user.id, %{
          "from_step_id" => from.id,
          "to_step_id" => to.id,
          "project_id" => project.id,
          "label" => "next"
        })
    end

    {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: judge.id})

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Structured Task",
        description: "test",
        level: "task",
        priority: "medium",
        tags: ["alpha", "beta"]
      })

    task = Sacrum.TestWorkspace.assign_workspace(task, user.id)
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{Task.workspace_daemon(task)}")

    %{user: user, project: project, task: task, judge: judge, consume: consume}
  end

  defp create_step(user, workflow, attrs) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(
        user.id,
        Map.merge(%{"workflow_id" => workflow.id, "project_id" => workflow.project_id}, attrs)
      )

    step
  end

  defp start_orchestrator(task, user) do
    {:ok, pid} =
      TaskFSMSupervisor.start_child({TaskOrchestrator, [task_id: task.id, user_id: user.id]})

    on_exit(fn ->
      if Process.alive?(pid), do: TaskFSMSupervisor.terminate_child(pid)
    end)

    pid
  end

  defp wait_until(fun, description, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Timed out waiting for #{description}")

      true ->
        Process.sleep(10)
        wait_until(fun, description, deadline)
    end
  end

  defp execution_for(task, step) do
    Repo.one(
      from(e in StepExecution,
        where: e.task_id == ^task.id and e.step_id == ^step.id,
        order_by: [desc: e.inserted_at],
        limit: 1
      )
    )
  end

  defp complete_execution(execution, result) do
    Accounts.StepExecutions.update(execution, %{status: "completed", output: result})
  end

  describe "a structured_inference step with a stubbed provider" do
    test "dispatches the resolved request and hands validated output to the next step" do
      %{user: user, task: task, judge: judge, consume: consume} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")

      execution = execution_for(task, judge)
      execution_id = execution.id

      resolved_state = %{"title" => "Structured Task", "tags" => ["alpha", "beta"]}

      assert execution.status == "started"
      assert execution.step_type == :structured_inference

      assert execution.config == %Config.StructuredInference{
               version: 1,
               provider: "typesafe",
               model: "jev-latest",
               state: resolved_state,
               fields: @fields
             }

      assert execution.model == "jev-latest"
      assert execution.model_provider == "typesafe"
      assert execution.context == %{}

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}, 1500
      assert payload.id == execution_id
      assert payload.state == resolved_state
      assert payload.output_schema == @fields
      assert payload.agent_config == %{"provider" => "typesafe", "model" => "jev-latest"}
      refute Map.has_key?(payload, :prompt)

      meta = %{"approved" => %{"probabilities" => %{"yes" => 0.9, "no" => 0.1}}}

      assert {:ok, completed} =
               complete_execution(
                 execution,
                 Jason.encode!(%{"output" => %{"approved" => "yes"}, "meta" => meta})
               )

      assert completed.status == "completed"
      assert Jason.decode!(completed.output) == %{"approved" => "yes"}

      assert completed.context == %{"structured_inference" => %{"meta" => meta}}
      assert completed.config == execution.config

      wait_until(fn -> execution_for(task, consume) end, "next step dispatch")
      consume_execution = execution_for(task, consume)

      assert %Config.LlmInference{prompt: "approved=yes p=0.9 named=yes"} =
               consume_execution.config
    end

    test "fails the execution when the provider result does not satisfy fields" do
      %{user: user, task: task, judge: judge, consume: consume} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      assert {:ok, failed} =
               complete_execution(
                 execution,
                 Jason.encode!(%{"output" => %{"approved" => "maybe"}})
               )

      assert failed.status == "failed"
      assert failed.output =~ "structured output rejected: output"
      assert failed.context == execution.context

      # The orchestrator either retries the step or fails the run; the next
      # step never starts.
      wait_until(
        fn ->
          Repo.aggregate(from(e in StepExecution, where: e.step_id == ^judge.id), :count) > 1 or
            Repo.exists?(from(r in TaskRun, where: r.task_id == ^task.id and r.status == :failed))
        end,
        "retry or run failure"
      )

      assert execution_for(task, consume) == nil

      refute Repo.exists?(
               from(e in StepExecution, where: e.task_id == ^task.id and e.status == "completed")
             )
    end

    test "rejects meta for properties outside fields and results without an output key" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      result =
        Jason.encode!(%{
          "output" => %{"approved" => "yes"},
          "meta" => %{"unknown" => %{"confidence" => 0.5}}
        })

      assert {:ok, %{status: "failed", output: output}} = complete_execution(execution, result)
      assert output =~ "structured output rejected: meta"

      assert %{"status" => "failed", "output" => output} =
               StructuredInference.complete(execution.config, %{}, ~s({"approved":"yes"}))

      assert output =~ "result must be an object with an output key"

      assert %{"output" => "structured output rejected: execution config is missing"} =
               StructuredInference.complete(nil, %{}, result)
    end

    test "harness updates cannot change the execution config or stored meta" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      forged = %{"structured_inference" => %{"meta" => %{}}, "harness" => %{"pid" => 1}}

      assert {:ok, updated} =
               Accounts.StepExecutions.update(execution, %{
                 status: "in_progress",
                 context: forged,
                 config: %{"fields" => %{}}
               })

      assert updated.context == %{"harness" => %{"pid" => 1}}
      assert updated.config == execution.config

      assert {:ok, %{status: "failed"}} =
               complete_execution(updated, Jason.encode!(%{"output" => %{"approved" => 1}}))
    end

    test "a duplicate completion re-validates instead of storing the raw result" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)
      result = Jason.encode!(%{"output" => %{"approved" => "no"}})

      assert {:ok, completed} = complete_execution(execution, result)
      assert {:ok, duplicate} = complete_execution(completed, result)

      assert duplicate.status == "completed"
      assert duplicate.output == completed.output
      assert Jason.decode!(duplicate.output) == %{"approved" => "no"}

      assert {:ok, same} = Accounts.StepExecutions.update(duplicate, %{status: "completed"})
      assert same.output == completed.output
    end

    test "fails the dispatch when a required state reference is missing" do
      config = Map.put(@structured_config, "state", "{{ steps.missing.output }}")
      %{user: user, task: task} = setup_workflow(config)

      {:ok, task_run} =
        Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{status: :queued})

      step =
        Sacrum.Repo.Schemas.WorkflowStep
        |> Repo.get!(task.current_step_id)
        |> Repo.preload(:workflow)

      assert {:error,
              {:config_render_failed, %{code: :step_config_render_failed, path: "$.state"}}} =
               ExecutionDispatcher.create_and_dispatch(task, step, task_run)

      assert Repo.get_by(StepExecution, task_run_id: task_run.id) == nil
      assert Repo.get!(TaskRun, task_run.id).status == :failed
      refute_received %Phoenix.Socket.Broadcast{event: "run_step"}
    end
  end
end
