defmodule SacrumWeb.GraphQL.HumanInputDraftTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.HumanInput, as: HumanInputConfig

  @schema %{
    "type" => "object",
    "properties" => %{
      "approved" => %{"type" => "boolean"},
      "reason" => %{"type" => "string"},
      "size" => %{"type" => "string", "enum" => ["s", "m"]}
    },
    "required" => ["approved", "reason"]
  }

  defp json_arg(value), do: value |> Jason.encode!() |> Jason.encode!()

  defp graphql(conn, query), do: post(conn, "/graphql", %{"query" => query})

  defp waiting_gate(config) do
    suffix = System.unique_integer([:positive])
    user = create_user(%{email: "draft-#{suffix}@example.com", username: "draft_#{suffix}"})
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Draft API"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Workflow"})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

    {:ok, step} =
      Accounts.WorkflowSteps.insert(
        user.id,
        workflow_step_attrs(%{
          "workflow_id" => workflow.id,
          "project_id" => project.id,
          "name" => "Gate",
          "step_type" => "human_input",
          "config" => config
        })
      )

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        workflow_id: workflow.id,
        step_id: step.id,
        project_id: project.id,
        step_name: step.name,
        status: "waiting"
      })

    {:ok, run} =
      %TaskRun{user_id: user.id, project_id: project.id}
      |> TaskRun.create_changeset(%{task_id: task.id, status: :waiting})
      |> Repo.insert()

    execution =
      execution
      |> Ecto.Changeset.change(
        task_run_id: run.id,
        config:
          struct(HumanInputConfig, %{
            version: 2,
            artifact: config["artifact"],
            output_schema: config["output_schema"]
          })
      )
      |> Repo.update!()

    run |> Ecto.Changeset.change(latest_step_execution_id: execution.id) |> Repo.update!()
    %{user: user, execution: execution}
  end

  test "set, read, and submit a draft", %{conn: conn} do
    %{user: user, execution: execution} =
      waiting_gate(%{"artifact" => "resolution", "output_schema" => @schema})

    conn = authenticate(conn, user)

    set =
      conn
      |> graphql("""
      mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"approved" => true})}) {
        executionId values missing complete invalid { path message } } }
      """)
      |> json_response(200)

    assert set["data"]["setHumanInputDraft"] == %{
             "executionId" => execution.id,
             "values" => %{"approved" => true},
             "missing" => ["reason"],
             "complete" => false,
             "invalid" => []
           }

    read =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql(
        ~s|{ humanInputDraft(executionId: "#{execution.id}") { values complete } stepExecution(id: "#{execution.id}") { draft { missing } } }|
      )
      |> json_response(200)

    assert read["data"]["humanInputDraft"] == %{
             "values" => %{"approved" => true},
             "complete" => false
           }

    assert read["data"]["stepExecution"]["draft"]["missing"] == ["reason"]

    incomplete =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql(
        ~s|mutation { submitHumanInputDraft(executionId: "#{execution.id}") { complete } }|
      )
      |> json_response(200)

    assert [%{"code" => "draft_incomplete", "missing" => ["reason"]}] =
             Enum.map(incomplete["errors"], & &1)

    submitted =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation {
        a: setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"reason" => "ok"})}) { complete }
        b: submitHumanInputDraft(executionId: "#{execution.id}") { complete values }
      }
      """)
      |> json_response(200)

    refute submitted["errors"]
    assert submitted["data"]["b"]["values"] == %{"approved" => true, "reason" => "ok"}
    assert Repo.get!(StepExecution, execution.id).status == "completed"
  end

  test "errors carry codes", %{conn: conn} do
    %{user: user, execution: execution} =
      waiting_gate(%{"artifact" => "resolution", "output_schema" => @schema})

    conn = authenticate(conn, user)

    unknown =
      conn
      |> graphql(
        ~s|mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"nope" => 1})}) { complete } }|
      )
      |> json_response(200)

    assert [%{"code" => "unknown_draft_field"}] = unknown["errors"]

    invalid =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql(
        ~s|mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"approved" => "x", "size" => "xl"})}) { complete } }|
      )
      |> json_response(200)

    assert [%{"code" => "invalid_human_input"}, %{"code" => "invalid_human_input"}] =
             invalid["errors"]
  end

  test "a gate without a draftable schema reports draftable false and rejects drafts",
       %{conn: conn} do
    %{user: user, execution: execution} =
      waiting_gate(%{
        "artifact" => "resolution",
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"nested" => %{"type" => "object"}}
        }
      })

    rejected =
      conn
      |> authenticate(user)
      |> graphql(
        ~s|mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"nested" => %{}})}) { complete } }|
      )
      |> json_response(200)

    assert [%{"code" => "human_input_not_draftable"}] = rejected["errors"]
  end

  describe "a gate that is no longer waiting" do
    defp set_mutation(execution, values),
      do:
        ~s|mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(values)}) { complete } }|

    defp submit_mutation(execution),
      do: ~s|mutation { submitHumanInputDraft(executionId: "#{execution.id}") { complete } }|

    defp run_graphql(conn, user, query),
      do: conn |> recycle() |> authenticate(user) |> graphql(query) |> json_response(200)

    test "a replayed submit is rejected and leaves the resolution untouched", %{conn: conn} do
      %{user: user, execution: execution} =
        waiting_gate(%{"artifact" => "resolution", "output_schema" => @schema})

      draft = %{"approved" => true, "reason" => "ok"}
      refute run_graphql(conn, user, set_mutation(execution, draft))["errors"]
      refute run_graphql(conn, user, submit_mutation(execution))["errors"]

      replay = run_graphql(conn, user, submit_mutation(execution))

      assert [%{"code" => "human_input_execution_not_waiting"}] = replay["errors"]
      resolved = Repo.get!(StepExecution, execution.id)
      assert resolved.status == "completed"
      assert resolved.draft == draft
    end

    test "set after resolution is rejected and does not change the draft", %{conn: conn} do
      %{user: user, execution: execution} =
        waiting_gate(%{"artifact" => "resolution", "output_schema" => @schema})

      draft = %{"approved" => true, "reason" => "ok"}
      refute run_graphql(conn, user, set_mutation(execution, draft))["errors"]
      refute run_graphql(conn, user, submit_mutation(execution))["errors"]

      late = run_graphql(conn, user, set_mutation(execution, %{"reason" => "changed"}))

      assert [%{"code" => "human_input_execution_not_waiting"}] = late["errors"]
      assert Repo.get!(StepExecution, execution.id).draft == draft
    end

    test "set and submit are rejected once the run has stopped", %{conn: conn} do
      %{user: user, execution: execution} =
        waiting_gate(%{"artifact" => "resolution", "output_schema" => @schema})

      draft = %{"approved" => true, "reason" => "ok"}
      refute run_graphql(conn, user, set_mutation(execution, draft))["errors"]

      Repo.get!(TaskRun, Repo.preload(execution, :task_run).task_run.id)
      |> Ecto.Changeset.change(status: :stopped)
      |> Repo.update!()

      assert [%{"code" => "human_input_execution_not_waiting"}] =
               run_graphql(conn, user, set_mutation(execution, %{"reason" => "x"}))["errors"]

      assert [%{"code" => "human_input_execution_not_waiting"}] =
               run_graphql(conn, user, submit_mutation(execution))["errors"]

      unresolved = Repo.get!(StepExecution, execution.id)
      assert unresolved.status == "waiting"
      assert unresolved.draft == draft
    end
  end

  test "another user cannot touch the draft", %{conn: conn} do
    %{execution: execution} = waiting_gate(%{"artifact" => "r", "output_schema" => @schema})
    suffix = System.unique_integer([:positive])
    other = create_user(%{email: "other-#{suffix}@example.com", username: "other_#{suffix}"})

    result =
      conn
      |> authenticate(other)
      |> graphql(
        ~s|mutation { setHumanInputDraft(executionId: "#{execution.id}", values: #{json_arg(%{"approved" => true})}) { complete } }|
      )
      |> json_response(200)

    assert [_ | _] = result["errors"]
    assert Repo.get!(StepExecution, execution.id).draft == %{}
  end
end
