defmodule Sacrum.Repo.WorkflowBundlesTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Repo.WorkflowBundles
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.{StepTransition, Workflow, WorkflowStep, WorkflowTransition}

  test "imports workflows without changing the project's default" do
    {user, project} = create_project()

    assert {:ok, result} = WorkflowBundles.import(user.id, project.id, successful_bundle())

    assert result.workflow_count == 2
    assert result.step_count == 4
    assert result.step_edge_count == 2
    assert result.workflow_edge_count == 2
    assert Map.keys(result.workflow_mappings) |> Enum.sort() == ["build", "review"]

    workflows = Repo.all(from workflow in Workflow, where: workflow.project_id == ^project.id)
    steps = Repo.all(from step in WorkflowStep, where: step.project_id == ^project.id)

    assert length(workflows) == 3
    assert length(steps) == 5
    assert Enum.count(workflows, & &1.is_default) == 1
    assert Enum.find(workflows, &(&1.name == "Backlog")).is_default
    refute Enum.find(workflows, &(&1.name == "Build")).is_default
    assert Repo.aggregate(StepTransition, :count) == 2
    assert Repo.aggregate(WorkflowTransition, :count) == 2

    assert Enum.all?(result.workflows, &(&1.initial_step_id != nil))

    assert result.workflow_steps |> Enum.map(& &1.name) |> Enum.sort() == [
             "Build finish",
             "Build start",
             "Review done",
             "Review start"
           ]
  end

  test "rolls back imported rows and preserves the existing default after route failure" do
    {user, project} = create_project()

    [existing_default] =
      Repo.all(
        from workflow in Workflow,
          where: workflow.project_id == ^project.id and workflow.is_default
      )

    assert {:error, %Ecto.Changeset{}} =
             WorkflowBundles.import(user.id, project.id, invalid_route_bundle())

    assert Repo.get!(Workflow, existing_default.id).is_default

    assert Repo.all(
             from workflow in Workflow,
               where: workflow.project_id == ^project.id,
               select: workflow.name
           ) == ["Backlog"]

    assert Repo.all(
             from step in WorkflowStep, where: step.project_id == ^project.id, select: step.name
           ) == ["Backlog"]

    assert Repo.aggregate(StepTransition, :count) == 0
    assert Repo.aggregate(WorkflowTransition, :count) == 0
  end

  test "rejects a project outside the authenticated user scope" do
    {_owner, project} = create_project()
    {caller, _caller_project} = create_project()

    assert {:error, :not_found} =
             WorkflowBundles.import(caller.id, project.id, successful_bundle())
  end

  defp create_project do
    suffix = Ecto.UUID.generate()

    {:ok, user} =
      Users.insert(%{
        email: "bundle-#{suffix}@example.com",
        username: "bundle#{String.slice(suffix, 0, 8)}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "Bundle #{suffix}"})
    {user, project}
  end

  defp successful_bundle do
    %{
      "schema_version" => 1,
      "workflows" => [
        %{
          "workflow_ref" => "build",
          "name" => "Build",
          "is_default" => true,
          "initial_step" => address("build", "start"),
          "steps" => [
            %{"step_ref" => "start", "name" => "Build start", "step_type" => "execute"},
            %{"step_ref" => "finish", "name" => "Build finish", "step_type" => "finish"}
          ]
        },
        %{
          "workflow_ref" => "review",
          "name" => "Review",
          "initial_step" => address("review", "start"),
          "steps" => [
            %{"step_ref" => "start", "name" => "Review start", "step_type" => "execute"},
            %{"step_ref" => "done", "name" => "Review done", "step_type" => "finish"}
          ]
        }
      ],
      "step_edges" => [
        step_edge("build", "start", "finish"),
        step_edge("review", "start", "done")
      ],
      "workflow_edges" => [
        workflow_edge("build", "review", "review", "start"),
        workflow_edge("review", "build", "build", "start")
      ]
    }
  end

  defp invalid_route_bundle do
    %{
      "schema_version" => 1,
      "workflows" => [
        %{
          "workflow_ref" => "broken",
          "name" => "Broken Default",
          "is_default" => true,
          "initial_step" => address("broken", "route"),
          "steps" => [
            %{
              "step_ref" => "route",
              "name" => "Route",
              "step_type" => "route",
              "route_config" => %{
                "version" => 1,
                "match_policy" => "exactly_one",
                "rules" => [
                  %{
                    "id" => "done",
                    "when" => %{
                      "ref" => "previous_output.route.result",
                      "op" => "eq",
                      "value" => "done"
                    },
                    "transition" => %{"type" => "intra_workflow", "step_ref" => "finish"}
                  }
                ],
                "default" => %{
                  "transition" => %{"type" => "intra_workflow", "step_ref" => "finish"}
                }
              }
            },
            %{"step_ref" => "finish", "name" => "Finish", "step_type" => "finish"}
          ]
        }
      ],
      "step_edges" => [step_edge("broken", "route", "finish")]
    }
  end

  defp address(workflow_ref, step_ref),
    do: %{"workflow_ref" => workflow_ref, "step_ref" => step_ref}

  defp step_edge(workflow_ref, from, to) do
    %{
      "from" => address(workflow_ref, from),
      "to" => address(workflow_ref, to)
    }
  end

  defp workflow_edge(
         from_workflow_ref,
         to_workflow_ref,
         destination_workflow_ref,
         destination_step_ref
       ) do
    %{
      "from_workflow_ref" => from_workflow_ref,
      "to_workflow_ref" => to_workflow_ref,
      "destination_step" => address(destination_workflow_ref, destination_step_ref)
    }
  end
end
