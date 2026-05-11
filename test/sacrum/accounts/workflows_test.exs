defmodule Sacrum.Accounts.WorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition

  import Ecto.Query

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_project(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  describe "insert/3" do
    test "creates workflow scoped to user_id and project_id" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(user.id, project.id, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
      assert workflow.name == "My Workflow"
    end

    test "accepts project struct and extracts ids" do
      user = create_user()
      project = create_project(user)

      assert {:ok, %Workflow{} = workflow} =
               Workflows.insert(project, %{name: "My Workflow"})

      assert workflow.user_id == user.id
      assert workflow.project_id == project.id
    end
  end

  describe "get_by/2" do
    test "returns workflow only if scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, workflow} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      # User1 can access their workflow
      assert {:ok, found} = Workflows.get_by(user1.id, conditions: [id: workflow.id])
      assert found.id == workflow.id
      assert found.user_id == user1.id

      # User2 cannot access user1's workflow
      assert {:error, :not_found} = Workflows.get_by(user2.id, conditions: [id: workflow.id])
    end
  end

  describe "insert/3 default-demotion semantics" do
    test "is_default: true demotes existing default and promotes the new workflow" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])
      assert auto_backlog.is_default == true

      assert {:ok, %Workflow{} = new_default} =
               Workflows.insert(user.id, project.id, %{name: "New Default", is_default: true})

      assert new_default.is_default == true
      assert Repo.get!(Workflow, auto_backlog.id).is_default == false

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert length(defaults) == 1
      assert hd(defaults).id == new_default.id
    end

    test "is_default: false (or unset) does not demote any existing default" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])

      assert {:ok, _} = Workflows.insert(user.id, project.id, %{name: "Plain WF"})

      assert {:ok, _} =
               Workflows.insert(user.id, project.id, %{name: "Explicit", is_default: false})

      assert Repo.get!(Workflow, auto_backlog.id).is_default == true

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert length(defaults) == 1
    end

    test "is_default: true with invalid attrs rolls back the demote (prior default untouched)" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])

      assert {:error, %Ecto.Changeset{}} =
               Workflows.insert(user.id, project.id, %{name: "", is_default: true})

      assert Repo.get!(Workflow, auto_backlog.id).is_default == true

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert length(defaults) == 1
      assert hd(defaults).id == auto_backlog.id
    end

    test "accepts string keys for is_default" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])

      assert {:ok, new_default} =
               Workflows.insert(user.id, project.id, %{
                 "name" => "Str Default",
                 "is_default" => true
               })

      assert new_default.is_default == true
      assert Repo.get!(Workflow, auto_backlog.id).is_default == false
    end
  end

  describe "update/2 default-demotion semantics" do
    test "setting is_default: true on a non-default workflow demotes the current default" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])

      {:ok, other} = Workflows.insert(user.id, project.id, %{name: "Other"})
      assert other.is_default == false

      assert {:ok, promoted} = Workflows.update(other, %{is_default: true})
      assert promoted.is_default == true

      assert Repo.get!(Workflow, auto_backlog.id).is_default == false

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert length(defaults) == 1
      assert hd(defaults).id == promoted.id
    end

    test "re-setting is_default: true on the workflow that is already default is a no-op" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])

      assert {:ok, still_default} = Workflows.update(auto_backlog, %{is_default: true})
      assert still_default.is_default == true

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert length(defaults) == 1
      assert hd(defaults).id == auto_backlog.id
    end

    test "setting is_default: false does not touch other workflows' is_default values" do
      user = create_user()
      project = create_project(user)
      [auto_backlog] = Workflows.list_by(user.id, conditions: [project_id: project.id])
      {:ok, other} = Workflows.insert(user.id, project.id, %{name: "Other"})

      assert {:ok, demoted} = Workflows.update(auto_backlog, %{is_default: false})
      assert demoted.is_default == false

      assert Repo.get!(Workflow, other.id).is_default == false

      defaults =
        Repo.all(from(w in Workflow, where: w.project_id == ^project.id and w.is_default == true))

      assert defaults == []
    end

    test "update with is_final: true while workflow has outgoing transitions returns is_final_with_outgoing_transitions" do
      user = create_user()
      project = create_project(user)
      {:ok, from_wf} = Workflows.insert(user.id, project.id, %{name: "From"})
      {:ok, to_wf} = Workflows.insert(user.id, project.id, %{name: "To"})

      Repo.insert!(%WorkflowTransition{
        from_workflow_id: from_wf.id,
        to_workflow_id: to_wf.id,
        user_id: user.id,
        project_id: project.id,
        label: "go"
      })

      assert {:error, :is_final_with_outgoing_transitions} =
               Workflows.update(from_wf, %{is_final: true})
    end
  end

  defp default_count(project_id) do
    Repo.one(
      from(w in Workflow,
        where: w.project_id == ^project_id and w.is_default == true,
        select: count(w.id)
      )
    )
  end

  describe "concurrent default-promotion" do
    test "concurrent insert(is_default: true) leaves exactly one default" do
      user = create_user()
      project = create_project(user)
      parent = self()

      assert default_count(project.id) == 1

      results =
        1..10
        |> Task.async_stream(
          fn i ->
            Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, parent, self())
            Workflows.insert(user.id, project.id, %{name: "Concurrent #{i}", is_default: true})
          end,
          max_concurrency: 10,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      # At least one must succeed; some may fail under the unique index — that is acceptable.
      successes =
        Enum.count(results, fn
          {:ok, {:ok, _}} -> true
          _ -> false
        end)

      assert successes >= 1
      assert default_count(project.id) == 1
    end
  end

  describe "list_by/2" do
    test "returns only workflows scoped to user" do
      user1 = create_user()
      project1 = create_project(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      project2 = create_project(user2)

      {:ok, _} = Workflows.insert(user1.id, project1.id, %{name: "User1 Workflow"})
      {:ok, _} = Workflows.insert(user2.id, project2.id, %{name: "User2 Workflow"})

      workflows = Workflows.list_by(user1.id)
      assert length(workflows) == 2
      assert Enum.all?(workflows, &(&1.user_id == user1.id))
    end

    test "filters by project_id" do
      user = create_user()
      project1 = create_project(user)
      {:ok, project2} = Projects.insert(user.id, %{name: "Project 2"})

      {:ok, _} = Workflows.insert(user.id, project1.id, %{name: "Workflow 1"})
      {:ok, _} = Workflows.insert(user.id, project2.id, %{name: "Workflow 2"})

      workflows = Workflows.list_by(user.id, conditions: [project_id: project1.id])
      assert length(workflows) == 2
      assert Enum.all?(workflows, &(&1.project_id == project1.id))
      assert Enum.any?(workflows, &(&1.name == "Backlog"))
      assert Enum.any?(workflows, &(&1.name == "Workflow 1"))
    end
  end
end
