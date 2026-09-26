defmodule Sacrum.Orchestrator.StructuredInferenceTest do
  @moduledoc """
  End-to-end contract for `structured_inference` steps with a stubbed provider
  harness: resolve `state`, dispatch the questions, validate the provider's
  answers against the schema derived from the questions, and expose the stored
  answers to the next step.
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

  @questions %{
    "approved" => %{
      "type" => "choice",
      "instructions" => "Is the task ready?",
      "criteria" => %{"yes" => "Ready to ship", "no" => nil}
    },
    "blocked" => %{"type" => "noul", "instructions" => "Is the task blocked?"},
    "risk" => %{
      "type" => "score",
      "instructions" => "Rate the risk",
      "criteria" => ["low", "high"]
    }
  }

  @structured_config %{
    "provider" => "typesafe",
    "model" => "jev-latest",
    "state" => %{"title" => "{{ task.title }}", "tags" => "{{ task.tags }}"},
    "questions" => @questions
  }

  # TypeSafe answers as the provider returns them.
  @answers %{
    "approved" => %{
      "type" => "choice",
      "choice" => "yes",
      "probabilities" => %{"yes" => 0.9, "no" => 0.1},
      "confidence" => 0.8
    },
    "blocked" => %{"type" => "noul", "noul" => 0.2},
    "risk" => %{
      "type" => "score",
      "score" => 0.25,
      "legend" => %{"0" => "low", "1" => "high"},
      "probabilities" => %{"0" => 0.75, "1" => 0.25},
      "confidence" => 0.5
    }
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
            "approved={{ execution.previous_output.approved.choice }} " <>
              "p={{ execution.previous_output.approved.probabilities.yes }} " <>
              "blocked={{ execution.previous_output.blocked.noul }} " <>
              "risk={{ steps.judge.output.risk.score }}",
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
    test "dispatches the questions and hands the stored answers to the next step" do
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
               questions: @questions
             }

      assert execution.model == "jev-latest"
      assert execution.model_provider == "typesafe"

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}, 1500
      assert payload.id == execution_id
      assert payload.state == resolved_state
      assert payload.questions == @questions
      assert payload.agent_config == %{"provider" => "typesafe", "model" => "jev-latest"}
      refute Map.has_key?(payload, :prompt)
      refute Map.has_key?(payload, :output_schema)

      result = Jason.encode!(@answers)
      assert {:ok, completed} = complete_execution(execution, result)

      assert completed.status == "completed"
      assert completed.output == result
      assert completed.context == execution.context
      assert completed.config == execution.config

      wait_until(fn -> execution_for(task, consume) end, "next step dispatch")
      consume_execution = execution_for(task, consume)

      assert %Config.LlmInference{prompt: "approved=yes p=0.9 blocked=0.2 risk=0.25"} =
               consume_execution.config
    end

    test "stores answers with additive provider fields verbatim" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      # Laya adds action.act_probability to every answer and confidence to noul.
      laya_answers =
        @answers
        |> Map.new(fn {id, answer} ->
          {id, Map.put(answer, "action", %{"act_probability" => 0.7})}
        end)
        |> put_in(["blocked", "confidence"], 0.6)

      result = Jason.encode!(laya_answers)

      assert {:ok, completed} = complete_execution(execution, result)
      assert completed.status == "completed"
      assert completed.output == result
    end

    test "fails the execution when the answers do not satisfy the questions" do
      %{user: user, task: task, judge: judge, consume: consume} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      assert {:ok, failed} =
               complete_execution(execution, Jason.encode!(Map.delete(@answers, "risk")))

      assert failed.status == "failed"
      assert failed.output =~ "structured output rejected: answers"
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

    test "rejects answers that do not match the questions" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      invalid = [
        Map.delete(@answers, "approved"),
        Map.put(@answers, "extra", %{"type" => "noul", "noul" => 0.5}),
        put_in(@answers, ["approved", "choice"], "maybe"),
        put_in(@answers, ["approved", "probabilities"], %{"yes" => 1.0}),
        put_in(@answers, ["approved", "probabilities"], %{"yes" => 0.5, "no" => 0.3, "x" => 0.2}),
        put_in(@answers, ["approved", "confidence"], 1.5),
        put_in(@answers, ["blocked", "noul"], -0.1),
        put_in(@answers, ["blocked", "type"], "choice"),
        put_in(@answers, ["risk", "score"], 2),
        put_in(@answers, ["risk", "legend"], %{"0" => "low"}),
        put_in(@answers, ["risk", "probabilities", "1"], 1.2)
      ]

      for answers <- invalid do
        assert %{"status" => "failed", "output" => "structured output rejected: answers " <> _} =
                 StructuredInference.complete(execution, Jason.encode!(answers)),
               "for #{inspect(answers)}"
      end

      assert %{"output" => "structured output rejected: answers must be valid JSON"} =
               StructuredInference.complete(execution, "not json")

      assert %{"output" => "structured output rejected: execution config is missing questions"} =
               StructuredInference.complete(%{execution | config: nil}, Jason.encode!(@answers))
    end

    test "harness updates cannot change the execution config" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)

      assert {:ok, updated} =
               Accounts.StepExecutions.update(execution, %{
                 status: "in_progress",
                 context: %{"harness" => %{"pid" => 1}},
                 config: %{"questions" => %{}}
               })

      assert updated.context == %{"harness" => %{"pid" => 1}}
      assert updated.config == execution.config

      assert {:ok, %{status: "failed"}} =
               complete_execution(updated, Jason.encode!(%{"approved" => 1}))
    end

    test "a duplicate completion re-validates instead of storing the raw result" do
      %{user: user, task: task, judge: judge} = setup_workflow()

      start_orchestrator(task, user)
      wait_until(fn -> execution_for(task, judge) end, "structured dispatch")
      execution = execution_for(task, judge)
      result = Jason.encode!(@answers)

      assert {:ok, completed} = complete_execution(execution, result)
      assert {:ok, duplicate} = complete_execution(completed, result)

      assert duplicate.status == "completed"
      assert duplicate.output == result

      assert {:ok, same} = Accounts.StepExecutions.update(duplicate, %{status: "completed"})
      assert same.output == result

      assert {:ok, %{status: "failed"}} = complete_execution(same, Jason.encode!(%{}))
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
