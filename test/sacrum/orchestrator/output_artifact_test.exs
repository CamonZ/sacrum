defmodule Sacrum.Orchestrator.OutputArtifactTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Orchestrator.{FSMData, OutputArtifact}
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @output_schema %{
    "type" => "object",
    "properties" => %{"result" => %{"type" => "string"}},
    "required" => ["result"],
    "additionalProperties" => false
  }

  defp create_scope do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "output-artifact-#{suffix}@example.com",
        username: "output_artifact_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Output Artifact Project"})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Output Artifact Task"})

    %{user: user, project: project, task: task}
  end

  defp step do
    %WorkflowStep{
      output_schema: @output_schema,
      persistence_options: %{"artifact" => %{"logical_name" => "step_result"}}
    }
  end

  defp execution(output) do
    %StepExecution{output: output}
  end

  test "persists decoded and canonical structured output as a task artifact" do
    %{user: user, project: project, task: task} = create_scope()
    data = %FSMData{user_id: user.id, project_id: project.id, task: task}

    assert :ok =
             OutputArtifact.persist(
               data,
               step(),
               execution("preamble\n```json\n{\"result\":\"ready\"}\n```\n")
             )

    assert [
             %{
               filename: "step_result.json",
               body: ~s({"result":"ready"}),
               logical_name: "step_result"
             }
           ] =
             Artifacts.list_for_subject(user.id, project.id, "task", task.id)
  end

  test "does not create an artifact when structured output is invalid" do
    %{user: user, project: project, task: task} = create_scope()
    data = %FSMData{user_id: user.id, project_id: project.id, task: task}

    assert {:error, :invalid_json} = OutputArtifact.persist(data, step(), execution("not json"))

    assert [] = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
  end

  test "does not create an artifact when structured output violates the schema" do
    %{user: user, project: project, task: task} = create_scope()
    data = %FSMData{user_id: user.id, project_id: project.id, task: task}

    assert {:error, {:validation_failed, _errors}} =
             OutputArtifact.persist(data, step(), execution(~s({"result":123})))

    assert [] = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
  end

  test "does not persist when the step has no artifact configuration" do
    %{user: user, project: project, task: task} = create_scope()
    data = %FSMData{user_id: user.id, project_id: project.id, task: task}
    step = %WorkflowStep{output_schema: @output_schema}

    assert :ok = OutputArtifact.persist(data, step, execution("not json"))
    assert [] = Artifacts.list_for_subject(user.id, project.id, "task", task.id)
  end
end
