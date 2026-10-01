defmodule Sacrum.Orchestrator.ExecuteDispatchTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, ExecutionHistory, PromptContext, PromptRenderer}
  alias Sacrum.Repo.Schemas.{StepExecution, Task, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Realtime.CommandBroadcaster

  @script "transform(execution.previous_output)"
  @output %{"name" => "example", "quantity" => 3, "unit_price" => 12}
  @schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}, "total" => %{"type" => "number"}},
    "required" => ["name", "total"],
    "additionalProperties" => false
  }

  setup do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "execute@example.com",
        username: "execute",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Execute"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Execute"})

    prepare =
      insert_step(workflow, "prepare", %{
        "script" => "prepare(task)",
        "output_schema" => %{"type" => "object"}
      })

    transform =
      insert_step(workflow, "transform", %{
        "script" => @script,
        "output_schema" => @schema
      })

    {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: transform.id})
    {:ok, daemon, bootstrap} = Repo.Daemons.create(user.id)
    {:ok, _, _, _} = Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Transformation",
        level: "task",
        workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/execute"}
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task = PromptRenderer.preload_for_rendering(task)
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{daemon.id}")
    {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

    %{
      user: user,
      project: project,
      workflow: workflow,
      prepare: prepare,
      transform: transform,
      task: task,
      task_run: task_run
    }
  end

  defp insert_step(workflow, name, config) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{name: name, step_type: "execute", config: config})

    Repo.preload(step, :workflow)
  end

  defp completed(ctx, step, output, overrides \\ %{}) do
    {:ok, execution} =
      Accounts.StepExecutions.insert(
        ctx.user.id,
        Map.merge(
          %{
            task_id: ctx.task.id,
            task_run_id: ctx.task_run.id,
            project_id: ctx.project.id,
            workflow_id: ctx.workflow.id,
            step_id: step.id,
            step_name: step.name,
            status: "completed",
            output: Jason.encode!(output)
          },
          overrides
        )
      )

    execution
  end

  defp attach(ctx, subject_type, subject_id, name) do
    {:ok, %{artifact: artifact}} =
      Accounts.Artifacts.create_and_link(
        ctx.user.id,
        ctx.project.id,
        %{filename: "#{name}.json", body: "private #{name} body"},
        %{subject_type: subject_type, subject_id: subject_id, logical_name: name}
      )

    artifact
  end

  test "persists all canonical namespaces and dispatches exactly the immutable snapshot", ctx do
    prior = completed(ctx, ctx.prepare, @output, %{duration_ms: 42})

    {:ok, _} =
      Accounts.Sections.insert(ctx.user.id, %{
        task_id: ctx.task.id,
        project_id: ctx.project.id,
        section_type: "constraint",
        content: "Keep JSON types"
      })

    {:ok, _} =
      Accounts.CodeRefs.insert_for_task(ctx.user.id, %{
        task_id: ctx.task.id,
        project_id: ctx.project.id,
        path: "lib/example.ex",
        line_start: 10,
        line_end: 20,
        name: "transform",
        description: "Reference"
      })

    project_artifact = attach(ctx, "project", ctx.project.id, "project_result")
    task_artifact = attach(ctx, "task", ctx.task.id, "task_result")
    run_artifact = attach(ctx, "task_run", ctx.task_run.id, "run_result")
    prior_artifact = attach(ctx, "step_execution", prior.id, "prior_result")
    task = Repo.get!(Task, ctx.task.id) |> PromptRenderer.preload_for_rendering()
    handoff = %{"selected" => [false, nil, "", "{{ literal.data }}"], "nested" => %{"n" => 3}}
    candidate = %StepExecution{step_id: ctx.transform.id, handoff: handoff}

    expected =
      PromptContext.build_context(
        task,
        ExecutionHistory.build_execution_data(task, candidate, ctx.task_run),
        ctx.transform,
        ctx.task_run
      )

    assert Map.keys(expected) |> Enum.sort() == ~w(artifacts execution inputs steps task workflow)
    assert expected["task"]["constraints"] == ["Keep JSON types"]

    assert [%{"path" => "lib/example.ex", "line_start" => 10, "line_end" => 20}] =
             expected["task"]["code_refs"]

    assert expected["execution"]["handoff"] === handoff
    assert expected["execution"]["previous_output"] === @output
    assert [%{"step_name" => "prepare", "output" => encoded}] = expected["execution"]["history"]
    assert Jason.decode!(encoded) == @output
    assert expected["inputs"] == %{}
    assert expected["workflow"]["current_step"] == "transform"

    assert expected["artifacts"] == %{
             "project" => %{"project_result" => %{"id" => project_artifact.id}},
             "task" => %{"task_result" => %{"id" => task_artifact.id}},
             "task_run" => %{"run_result" => %{"id" => run_artifact.id}},
             "step_execution" => %{
               "history" => [%{"prior_result" => %{"id" => prior_artifact.id}}]
             }
           }

    refute inspect(expected) =~ "private"

    assert {:ok, execution} =
             ExecutionDispatcher.create_and_dispatch(task, ctx.transform, ctx.task_run, handoff)

    assert execution.step_type == :execute
    assert execution.harness == nil
    assert execution.context == %{}
    assert %Config.Execute{version: 1, script: @script, output_schema: @schema} = execution.config
    assert execution.config.context === expected
    assert Repo.get!(StepExecution, execution.id).config == execution.config
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}

    assert payload == %{
             id: execution.id,
             task_id: task.id,
             project_id: ctx.project.id,
             worktree: "/tmp/execute",
             step_type: "execute",
             version: 1,
             script: @script,
             context: expected,
             output_schema: @schema
           }

    {:ok, changed_step} =
      Accounts.WorkflowSteps.update(ctx.transform, %{
        config: %{"script" => "changed", "output_schema" => %{"type" => "string"}}
      })

    {:ok, _} = Accounts.Tasks.update(task, %{title: "Changed task"})

    {:ok, _} =
      Accounts.Artifacts.update(ctx.user.id, task_artifact.id, %{body: "changed body"}, %{
        logical_name: "renamed"
      })

    {:ok, _} = Accounts.StepExecutions.update(prior, %{output: ~s({"changed":true})})
    changed_task = Repo.get!(Task, task.id) |> PromptRenderer.preload_for_rendering()
    persisted = Repo.get!(StepExecution, execution.id)
    assert persisted.config == execution.config

    assert {:ok, reused} =
             ExecutionDispatcher.create_and_dispatch(
               changed_task,
               changed_step,
               ctx.task_run,
               nil,
               reuse_active: true,
               active_execution: persisted
             )

    assert reused.id == execution.id
    assert reused.config.context === expected

    assert Repo.aggregate(from(e in StepExecution, where: e.step_id == ^ctx.transform.id), :count) ==
             1

    refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}

    assert :ok =
             CommandBroadcaster.broadcast_run_step(
               %{task: changed_task, step: changed_step, execution: persisted},
               Task.workspace_daemon(task)
             )

    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: ^payload}

    assert {:ok, _} =
             Accounts.StepExecutions.update(persisted, %{
               status: "completed",
               output: ~s({"name":"example","total":36}),
               config: %{"context" => %{}},
               context: %{"audit" => "changed"}
             })

    persisted = Repo.get!(StepExecution, execution.id)
    assert persisted.config == execution.config
    assert persisted.context == %{"audit" => "changed"}
    assert WorkflowStep.output_schema(persisted) == @schema

    consumer =
      insert_step(ctx.workflow, "consumer", %{
        "script" => "consume(steps.transform.output)",
        "output_schema" => %{"type" => "object"}
      })

    assert {:ok, next} =
             ExecutionDispatcher.create_and_dispatch(changed_task, consumer, ctx.task_run)

    assert next.config.context["execution"]["previous_output"] == %{
             "name" => "example",
             "total" => 36
           }

    assert next.config.context["steps"]["transform"]["output"] == %{
             "name" => "example",
             "total" => 36
           }

    assert next.task_run_id == execution.task_run_id
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: next_payload}
    assert next_payload.context === next.config.context
  end

  test "context preserves nested JSON types and literal template text without a second render",
       ctx do
    output =
      Map.merge(@output, %{
        "active" => false,
        "nothing" => nil,
        "empty" => "",
        "object" => %{},
        "items" => [1, true, nil, %{"value" => 2}],
        "text" => "\"quote\"\n\\{{ literal.data }}"
      })

    completed(ctx, ctx.prepare, output)

    {:ok, transform} =
      Accounts.WorkflowSteps.update(ctx.transform, %{
        config: %{"script" => "// {{ task.title }}\ntransform(execution.previous_output)"}
      })

    assert {:ok, execution} =
             ExecutionDispatcher.create_and_dispatch(ctx.task, transform, ctx.task_run)

    assert execution.config.context["execution"]["previous_output"] === output
    assert execution.config.context["steps"]["prepare"]["output"] === output
    assert execution.config.script == "// Transformation\ntransform(execution.previous_output)"
    assert Repo.get!(StepExecution, execution.id).config.context === execution.config.context
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
    assert payload.context === execution.config.context
  end

  test "schema-decoded scalar, null, false and empty outputs round-trip in previous and named context",
       ctx do
    for output <- [false, nil, true, 36, 1.5, "", [], %{}, [1, false, nil]] do
      {:ok, run} =
        Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :queued})

      completed(%{ctx | task_run: run}, ctx.prepare, output)

      assert {:ok, execution} =
               ExecutionDispatcher.create_and_dispatch(ctx.task, ctx.transform, run)

      assert Map.fetch!(execution.config.context["execution"], "previous_output") === output
      assert Map.fetch!(execution.config.context["steps"]["prepare"], "output") === output
      assert Repo.get!(StepExecution, execution.id).config.context === execution.config.context
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.context === execution.config.context
    end
  end

  test "strict Liquid errors fail before creating an execution or command", ctx do
    for {script, message} <- [
          {"{% if task.title %}", "endif"},
          {"{{ absent.variable }}", "absent"},
          {"{{ execution.previous_output }}", "previous_output"},
          {"{{ steps.prepare.output.quantity }}", "prepare"},
          {"{{ task.tags }}", "available in context"}
        ] do
      {:ok, run} =
        Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :queued})

      {:ok, step} = Accounts.WorkflowSteps.update(ctx.transform, %{config: %{"script" => script}})

      assert {:error, {:config_render_failed, %{path: "$.script", message: reason}}} =
               ExecutionDispatcher.create_and_dispatch(ctx.task, step, run)

      assert String.downcase(reason) =~ message

      assert Repo.aggregate(from(e in StepExecution, where: e.task_run_id == ^run.id), :count) ==
               0

      assert Repo.get!(Sacrum.Repo.Schemas.TaskRun, run.id).status == :failed
      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}
    end

    assert Repo.get!(Task, ctx.task.id).started_at == nil
  end

  test "new run context omits old outputs while native variable references remain daemon-owned",
       ctx do
    completed(ctx, ctx.prepare, @output)

    {:ok, run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :queued})

    assert {:ok, execution} =
             ExecutionDispatcher.create_and_dispatch(ctx.task, ctx.transform, run)

    assert execution.config.script == @script
    assert execution.config.context["steps"] == %{}
    assert execution.config.context["execution"]["history"] == []
    refute Map.has_key?(execution.config.context["execution"], "previous_output")
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
    assert payload.context === execution.config.context
  end

  test "large, deep, and wide previous outputs dispatch without truncation", ctx do
    for output <- [
          Enum.to_list(1..4097),
          String.duplicate("x", 1_048_577),
          Enum.reduce(1..33, nil, fn _, value -> [value] end)
        ] do
      {:ok, run} =
        Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :queued})

      completed(%{ctx | task_run: run}, ctx.prepare, output)

      assert {:ok, execution} =
               ExecutionDispatcher.create_and_dispatch(ctx.task, ctx.transform, run)

      assert Map.fetch!(execution.config.context["execution"], "previous_output") === output
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.context === execution.config.context
    end
  end

  test "daemon completion advances an execute step through the existing TaskRun lifecycle", ctx do
    completed(ctx, ctx.prepare, @output)

    {:ok, finish} =
      Accounts.WorkflowSteps.insert(ctx.workflow, %{
        name: "finish",
        step_type: "finish",
        harness: "codex"
      })

    {:ok, _} =
      Accounts.StepTransitions.insert(ctx.user.id, %{
        from_step_id: ctx.transform.id,
        to_step_id: finish.id,
        project_id: ctx.project.id
      })

    :ok = connect_daemon(Task.workspace_daemon(ctx.task), ctx.user.id)

    pid =
      start_supervised!(
        {Sacrum.Orchestrator.TaskOrchestrator,
         task_id: ctx.task.id, user_id: ctx.user.id, task_run_id: ctx.task_run.id}
      )

    ref = Process.monitor(pid)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "run_step",
                     payload: %{id: id, step_type: "execute"}
                   },
                   2000

    execution = Repo.get!(StepExecution, id)

    assert {:ok, _} =
             Accounts.StepExecutions.update(execution, %{
               status: "completed",
               output: ~s({"name":"example","total":36})
             })

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    assert Repo.get!(Task, ctx.task.id).current_step_id == finish.id
    assert Repo.get!(Sacrum.Repo.Schemas.TaskRun, ctx.task_run.id).status == :completed
    assert Repo.get!(StepExecution, id).output == ~s({"name":"example","total":36})
  end

  test "daemon evaluation/schema/capacity failures are persisted and exhausted by existing retry policy",
       ctx do
    completed(ctx, ctx.prepare, @output)
    :ok = connect_daemon(Task.workspace_daemon(ctx.task), ctx.user.id)

    pid =
      start_supervised!(
        {Sacrum.Orchestrator.TaskOrchestrator,
         task_id: ctx.task.id, user_id: ctx.user.id, task_run_id: ctx.task_run.id}
      )

    ref = Process.monitor(pid)

    for reason <- [
          "evaluation failed",
          "output schema mismatch",
          "daemon capacity",
          "evaluation failed",
          "output schema mismatch"
        ] do
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "run_step",
                       payload: %{id: id, step_type: "execute"}
                     },
                     2000

      execution = Repo.get!(StepExecution, id)
      assert execution.task_run_id == ctx.task_run.id

      assert {:ok, failed} =
               Accounts.StepExecutions.update(execution, %{status: "failed", output: reason})

      assert failed.status == "failed"
      assert failed.output == reason
    end

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, ctx.task_run.id)
    assert run.status == :failed
    assert run.outcome_kind == "retry_exhausted"
    assert Repo.get!(Task, ctx.task.id).current_step_id == ctx.transform.id
    assert Repo.get!(Task, ctx.task.id).completed_at == nil

    attempts =
      Repo.all(
        from(e in StepExecution,
          where: e.step_id == ^ctx.transform.id and e.task_run_id == ^ctx.task_run.id
        )
      )

    assert length(attempts) == Sacrum.Orchestrator.Retry.max_retries()
    assert Enum.all?(attempts, &(&1.status == "failed"))
  end

  test "history does not expose rows outside the exact user/project/task/run scope", ctx do
    {:ok, other_user} =
      Repo.Users.insert(%{
        email: "other-execute@example.com",
        username: "other_execute",
        password: "password123"
      })

    {:ok, other_project} = Accounts.Projects.insert(ctx.user.id, %{name: "Other"})
    {:ok, foreign_project} = Accounts.Projects.insert(other_user.id, %{name: "Foreign"})

    {:ok, foreign_task} =
      Accounts.Tasks.insert(other_user.id, foreign_project.id, %{title: "Foreign"})

    {:ok, other_task} =
      Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{title: "Other", level: "task"})

    {:ok, other_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :completed})

    attach(%{ctx | project: other_project}, "project", other_project.id, "outside_project")

    attach(
      %{ctx | user: other_user, project: foreign_project},
      "task",
      foreign_task.id,
      "outside_owner"
    )

    attach(ctx, "task", other_task.id, "outside_task")
    attach(ctx, "task_run", other_run.id, "outside_run")
    outside = completed(%{ctx | task_run: other_run}, ctx.prepare, @output)
    attach(ctx, "step_execution", outside.id, "outside_history")

    for overrides <- [
          %{user_id: other_user.id},
          %{project_id: other_project.id},
          %{task_id: other_task.id},
          %{task_run_id: other_run.id}
        ] do
      attrs =
        Map.merge(
          %{
            user_id: ctx.user.id,
            project_id: ctx.project.id,
            task_id: ctx.task.id,
            task_run_id: ctx.task_run.id,
            step_id: ctx.prepare.id,
            step_name: "prepare",
            step_type: :execute,
            status: "completed",
            output: Jason.encode!(@output)
          },
          overrides
        )

      attrs
      |> then(&struct(StepExecution, &1))
      |> StepExecution.create_changeset(%{})
      |> StepExecution.put_config(ctx.prepare.config)
      |> Repo.insert!()
    end

    dispatched = %StepExecution{step_id: ctx.transform.id, handoff: nil}
    data = ExecutionHistory.build_execution_data(ctx.task, dispatched, ctx.task_run)
    assert data.history == []
    refute Map.has_key?(data, :previous)
    context = PromptContext.build_context(ctx.task, data, ctx.transform, ctx.task_run)
    assert context["steps"] == %{}
    refute Map.has_key?(context["execution"], "previous_output")

    assert context["artifacts"] == %{
             "project" => %{},
             "task" => %{},
             "task_run" => %{},
             "step_execution" => %{"history" => []}
           }

    assert {:ok, execution} =
             ExecutionDispatcher.create_and_dispatch(ctx.task, ctx.transform, ctx.task_run)

    assert execution.config.context === context
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
    assert payload.context === context
  end
end
