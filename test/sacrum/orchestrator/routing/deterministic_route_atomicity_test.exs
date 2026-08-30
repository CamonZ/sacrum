defmodule Sacrum.Orchestrator.Routing.DeterministicRouteAtomicityTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.ExecutionDispatcher
  alias Sacrum.Orchestrator.Routing.RouteStep
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun}
  alias Sacrum.Routing.RouteConfig

  describe "handle_deterministic_route_step/3" do
    test "atomically persists a rendered handoff without transition metadata and dispatches it to the destination" do
      fixture = configured_intra_fixture()

      assert {:next_state, :awaiting_execution, returned_data} =
               RouteStep.handle_deterministic_route_step(
                 fixture.data,
                 fixture.route,
                 fixture.program
               )

      assert returned_data.pending_handoff == fixture.handoff

      assert %Task{current_step_id: destination_id} = Repo.get!(Task, fixture.task.id)
      assert destination_id == fixture.destination.id

      assert %StepExecution{
               id: audit_id,
               task_run_id: task_run_id,
               step_id: route_step_id,
               status: "completed",
               handoff: handoff,
               context: %{
                 "route" => %{
                   "mode" => "deterministic",
                   "source_execution_id" => source_execution_id,
                   "config_version" => 1,
                   "matched_rule_id" => "approved",
                   "used_default" => false,
                   "context" => %{
                     "execution" => %{"step_visit_count" => 1},
                     "previous_output" => %{
                       "route" => %{
                         "result" => "approved",
                         "handoff" => context_handoff
                       }
                     }
                   }
                 }
               },
               transition_result: transition_result
             } = deterministic_audit(fixture.task.id, fixture.route.id)

      assert route_step_id == fixture.route.id
      assert task_run_id == fixture.task_run.id
      assert source_execution_id == fixture.source_execution.id
      assert handoff == fixture.handoff
      assert context_handoff == fixture.source_handoff
      refute Map.has_key?(handoff, "type")
      refute Map.has_key?(handoff, "step_id")
      refute Map.has_key?(handoff, "workflow_id")

      assert Jason.decode!(transition_result) == %{
               "dest_id" => fixture.destination.id,
               "transition_type" => "intra_workflow"
             }

      assert %TaskRun{
               latest_step_execution_id: ^audit_id,
               status: :executing,
               outcome_kind: nil
             } = Repo.get!(TaskRun, fixture.task_run.id)

      assert Repo.get!(StepExecution, fixture.source_execution.id).transition_result == nil

      updated_task =
        Task
        |> Repo.get!(fixture.task.id)
        |> Sacrum.Orchestrator.PromptRenderer.preload_for_rendering()

      assert {:ok, destination_execution} =
               ExecutionDispatcher.create_and_dispatch(
                 fixture.data.user_id,
                 updated_task,
                 fixture.destination.id,
                 fixture.task_run.id,
                 returned_data.pending_handoff
               )

      assert destination_execution.handoff == fixture.handoff
      assert Repo.get!(StepExecution, destination_execution.id).handoff == fixture.handoff
    end

    test "atomically persists an inter-workflow audit with the terminal TaskRun outcome" do
      fixture = configured_inter_fixture()

      assert {:stop, :normal, returned_data} =
               RouteStep.handle_deterministic_route_step(
                 fixture.data,
                 fixture.route,
                 fixture.program
               )

      assert returned_data.pending_handoff == fixture.handoff

      assert %Task{
               workflow_id: workflow_id,
               current_step_id: current_step_id,
               status: "done",
               completed_at: completed_at
             } = Repo.get!(Task, fixture.task.id)

      assert workflow_id == fixture.destination_workflow.id
      assert current_step_id == fixture.destination.id
      assert completed_at

      assert %StepExecution{
               id: audit_id,
               workflow_id: source_workflow_id,
               handoff: handoff,
               context: %{
                 "route" => %{
                   "matched_rule_id" => "approved",
                   "source_execution_id" => source_execution_id,
                   "used_default" => false
                 }
               },
               transition_result: transition_result
             } = deterministic_audit(fixture.task.id, fixture.route.id)

      assert source_workflow_id == fixture.workflow.id
      assert source_execution_id == fixture.source_execution.id
      assert handoff == fixture.handoff

      assert Jason.decode!(transition_result) == %{
               "dest_id" => fixture.destination_workflow.id,
               "transition_type" => "inter_workflow"
             }

      assert %TaskRun{
               latest_step_execution_id: ^audit_id,
               status: :completed,
               outcome_kind: "completed",
               outcome_context: %{
                 "reason" => "finish_step",
                 "current_step_id" => destination_id
               }
             } = Repo.get!(TaskRun, fixture.task_run.id)

      assert destination_id == fixture.destination.id
      assert Repo.get!(StepExecution, fixture.source_execution.id).transition_result == nil
    end

    test "rolls back every persistence stage without exposing a partial route decision" do
      Enum.each([:audit, :cursor, :task], fn stage ->
        fixture = configured_intra_fixture()
        trigger = install_failure_trigger(stage)

        try do
          assert_raise Postgrex.Error, fn ->
            RouteStep.handle_deterministic_route_step(
              fixture.data,
              fixture.route,
              fixture.program
            )
          end

          assert_no_partial_route_commit(fixture)
        after
          remove_failure_trigger(trigger)
        end
      end)

      fixture = configured_inter_fixture()
      trigger = install_failure_trigger(:completion)

      try do
        assert_raise Postgrex.Error, fn ->
          RouteStep.handle_deterministic_route_step(fixture.data, fixture.route, fixture.program)
        end

        assert_no_partial_route_commit(fixture)
      after
        remove_failure_trigger(trigger)
      end
    end

    test "omitted and empty handoff templates do not persist or dispatch a handoff" do
      Enum.each([nil, %{}], fn handoff_template ->
        fixture = configured_intra_fixture(handoff_template)

        assert {:next_state, :awaiting_execution, returned_data} =
                 RouteStep.handle_deterministic_route_step(
                   fixture.data,
                   fixture.route,
                   fixture.program
                 )

        assert returned_data.pending_handoff == nil
        assert deterministic_audit(fixture.task.id, fixture.route.id).handoff == nil

        updated_task =
          Task
          |> Repo.get!(fixture.task.id)
          |> Sacrum.Orchestrator.PromptRenderer.preload_for_rendering()

        assert {:ok, destination_execution} =
                 ExecutionDispatcher.create_and_dispatch(
                   fixture.data.user_id,
                   updated_task,
                   fixture.destination.id,
                   fixture.task_run.id,
                   returned_data.pending_handoff
                 )

        assert destination_execution.handoff == nil
        assert Repo.get!(StepExecution, destination_execution.id).handoff == nil
      end)
    end

    test "fails before committing a route when a selected template reads a missing handoff value" do
      fixture =
        configured_intra_fixture(%{
          "review" => "{{ previous_output.route.handoff.missing }}"
        })

      assert {:next_state, :failed, _failed_data} =
               RouteStep.handle_deterministic_route_step(
                 fixture.data,
                 fixture.route,
                 fixture.program
               )

      assert_no_partial_route_commit(fixture)
    end
  end

  defp configured_intra_fixture(handoff_template \\ route_handoff_template()) do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project, "Intra route workflow")

    source =
      create_step(user, workflow, %{
        "name" => "source",
        "step_order" => 1,
        "output_schema" => predecessor_schema(["review"])
      })

    route =
      create_step(user, workflow, %{
        "name" => "route",
        "step_order" => 2,
        "step_type" => "route",
        "prompt" => nil
      })

    destination = create_step(user, workflow, %{"name" => "review", "step_order" => 3})

    create_step_transition(user, source, route)
    create_step_transition(user, route, destination)

    {:ok, route} =
      Accounts.WorkflowSteps.update(route, %{
        route_config:
          route_config(
            %{"type" => "intra_workflow", "step_id" => destination.id},
            handoff_template
          )
      })

    {:ok, _workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})
    task = create_task(user, project, workflow)
    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: route.id))
    task_run = create_task_run(user, task)
    source_handoff = %{"review" => "needed"}
    handoff = rendered_handoff(source_handoff)

    source_execution =
      create_source_execution(user, task, workflow, source, task_run, source_handoff)

    task_run = update_cursor(task_run, source_execution.id)

    {:ok, program} = RouteConfig.decode(route.route_config)

    %{
      data: fsm_data(user, project, task, task_run, workflow, source, route, destination),
      destination: destination,
      handoff: handoff,
      program: program,
      route: route,
      source_execution: source_execution,
      source_handoff: source_handoff,
      task: task,
      task_run: task_run,
      workflow: workflow
    }
  end

  defp configured_inter_fixture do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project, "Source route workflow")
    destination_workflow = create_workflow(user, project, "Destination route workflow")

    source =
      create_step(user, workflow, %{
        "name" => "source",
        "step_order" => 1,
        "output_schema" => predecessor_schema(["review"])
      })

    route =
      create_step(user, workflow, %{
        "name" => "route",
        "step_order" => 2,
        "step_type" => "route",
        "prompt" => nil
      })

    destination =
      create_step(user, destination_workflow, %{
        "name" => "done",
        "step_type" => "finish",
        "prompt" => nil
      })

    create_step_transition(user, source, route)
    create_workflow_transition(user, workflow, destination_workflow, destination)

    {:ok, route} =
      Accounts.WorkflowSteps.update(route, %{
        route_config:
          route_config(
            %{"type" => "inter_workflow", "workflow_id" => destination_workflow.id},
            route_handoff_template()
          )
      })

    {:ok, _workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})
    task = create_task(user, project, workflow)
    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: route.id))
    task_run = create_task_run(user, task)
    source_handoff = %{"review" => "needed"}
    handoff = rendered_handoff(source_handoff)

    source_execution =
      create_source_execution(user, task, workflow, source, task_run, source_handoff)

    task_run = update_cursor(task_run, source_execution.id)

    {:ok, program} = RouteConfig.decode(route.route_config)

    %{
      data: fsm_data(user, project, task, task_run, workflow, source, route),
      destination: destination,
      destination_workflow: destination_workflow,
      handoff: handoff,
      program: program,
      route: route,
      source_execution: source_execution,
      source_handoff: source_handoff,
      task: task,
      task_run: task_run,
      workflow: workflow
    }
  end

  defp assert_no_partial_route_commit(fixture) do
    assert %Task{workflow_id: workflow_id, current_step_id: current_step_id} =
             Repo.get!(Task, fixture.task.id)

    assert workflow_id == fixture.workflow.id
    assert current_step_id == fixture.route.id

    assert %TaskRun{latest_step_execution_id: cursor_id, status: :executing} =
             Repo.get!(TaskRun, fixture.task_run.id)

    assert cursor_id == fixture.source_execution.id

    assert Repo.aggregate(
             from(e in StepExecution,
               where: e.task_id == ^fixture.task.id and e.step_id == ^fixture.route.id
             ),
             :count
           ) == 0
  end

  defp deterministic_audit(task_id, route_step_id) do
    Repo.one!(
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.step_id == ^route_step_id and e.status == "completed"
      )
    )
  end

  defp install_failure_trigger(stage) do
    suffix = System.unique_integer([:positive])
    function = "fail_deterministic_route_#{stage}_#{suffix}"
    trigger = "fail_deterministic_route_#{stage}_trigger_#{suffix}"
    {table, event, condition} = failure_trigger_definition(stage)

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'forced deterministic route #{stage} failure';
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE #{event} ON #{table}
    FOR EACH ROW
    #{condition}
    EXECUTE FUNCTION #{function}();
    """)

    %{function: function, table: table, trigger: trigger}
  end

  defp remove_failure_trigger(%{function: function, table: table, trigger: trigger}) do
    Repo.query!("DROP TRIGGER #{trigger} ON #{table}")
    Repo.query!("DROP FUNCTION #{function}()")
  end

  defp failure_trigger_definition(:audit),
    do: {"step_executions", "INSERT", "WHEN (NEW.step_type = 'route')"}

  defp failure_trigger_definition(:cursor),
    do: {"task_runs", "UPDATE", "WHEN (NEW.status = 'executing')"}

  defp failure_trigger_definition(:task), do: {"tasks", "UPDATE", ""}

  defp failure_trigger_definition(:completion),
    do: {"task_runs", "UPDATE", "WHEN (NEW.status = 'completed')"}

  defp fsm_data(user, project, task, task_run, workflow, source, route, destination \\ nil) do
    steps =
      [source, route, destination]
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.id, &1})

    transitions =
      case destination do
        nil -> %{source.id => [route.id], route.id => []}
        destination -> %{source.id => [route.id], route.id => [destination.id]}
      end

    %{
      user_id: user.id,
      project_id: project.id,
      task: task,
      task_run_id: task_run.id,
      workflow: workflow,
      steps: steps,
      transitions: transitions,
      slot_id: nil,
      pending_handoff: nil
    }
  end

  defp create_source_execution(user, task, workflow, source, task_run, handoff) do
    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        project_id: task.project_id,
        workflow_id: workflow.id,
        task_run_id: task_run.id,
        step_id: source.id,
        step_name: source.name,
        step_type: :execute,
        status: "completed",
        output: Jason.encode!(%{"route" => %{"result" => "approved", "handoff" => handoff}})
      })

    execution
  end

  defp update_cursor(task_run, execution_id) do
    {:ok, task_run} =
      task_run
      |> TaskRun.update_changeset(%{latest_step_execution_id: execution_id})
      |> Repo.update()

    task_run
  end

  defp route_config(transition, handoff_template) do
    rule =
      maybe_put_handoff(
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => transition
        },
        handoff_template
      )

    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [rule],
      "default" => %{"transition" => transition}
    }
  end

  defp route_handoff_template do
    %{
      "review" => "{{ previous_output.route.handoff.review }}",
      "result" => "{{ previous_output.route.result }}",
      "visit" => "{{ execution.step_visit_count }}"
    }
  end

  defp rendered_handoff(source_handoff) do
    %{
      "review" => source_handoff["review"],
      "result" => "approved",
      "visit" => 1
    }
  end

  defp maybe_put_handoff(decision, nil), do: decision
  defp maybe_put_handoff(decision, handoff), do: Map.put(decision, "handoff", handoff)

  defp predecessor_schema(handoff_keys) do
    handoff_properties = Map.new(handoff_keys, &{&1, %{"type" => "string"}})

    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => ["approved"]},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => handoff_keys,
              "properties" => handoff_properties
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end

  defp create_task_run(user, task) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    task_run
  end

  defp create_task(user, project, workflow) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Deterministic route task"})
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_step(user, workflow, attrs) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "name" => Map.fetch!(attrs, "name"),
        "step_order" => Map.get(attrs, "step_order", 1),
        "step_type" => Map.get(attrs, "step_type", "execute"),
        "prompt" => Map.get(attrs, "prompt", "Run this step"),
        "output_schema" => Map.get(attrs, "output_schema"),
        "workflow_id" => workflow.id,
        "project_id" => workflow.project_id
      })

    step
  end

  defp create_step_transition(user, source, destination) do
    {:ok, _transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => source.id,
        "to_step_id" => destination.id,
        "project_id" => source.project_id
      })
  end

  defp create_workflow_transition(user, source, destination, target_step) do
    {:ok, _transition} =
      Accounts.WorkflowTransitions.insert(user.id, %{
        "from_workflow_id" => source.id,
        "to_workflow_id" => destination.id,
        "project_id" => source.project_id,
        "target_step_id" => target_step.id
      })
  end

  defp create_workflow(user, project, name) do
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: name})
    workflow
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Deterministic route project"})
    project
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "deterministic-route-#{suffix}@example.com",
        username: "deterministicroute#{suffix}",
        password: "password123"
      })

    user
  end
end
