defmodule SacrumWeb.Graphql.TaskDeletionTest do
  use SacrumWeb.ConnCase, async: false

  alias Sacrum.Accounts.{StepExecutions, TaskRuns, Tasks}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink, CodeRef, SessionLog, StepExecution}
  alias Sacrum.Repo.Schemas.{Task, TaskDependency, TaskRun, TaskSection}
  alias Sacrum.Repo.Tasks, as: TasksRepo

  setup do
    user = create_user()
    {:ok, project} = Sacrum.Accounts.Projects.insert(user.id, %{name: "Task deletion"})
    %{user: user, project: project}
  end

  test "default GraphQL cascade deletes three-level lineage and owned records only", ctx do
    tree = tree(ctx)
    unrelated = history(ctx, task(ctx, "Unrelated"))
    {:ok, inbound} = Sacrum.Repo.TaskDependencies.add_dependency(unrelated.task, tree.epic.task)
    {:ok, outbound} = Sacrum.Repo.TaskDependencies.add_dependency(tree.child.task, unrelated.task)
    another_task = task(ctx, "Another unrelated task")

    {:ok, retained_edge} =
      Sacrum.Repo.TaskDependencies.add_dependency(another_task, unrelated.task)

    artifact = shared_artifact(ctx, tree.epic.task, unrelated.task)

    other_user = create_user(%{email: "other@example.com", username: "other"})
    {:ok, other_project} = Sacrum.Accounts.Projects.insert(other_user.id, %{name: "Other"})
    other_ctx = %{user: other_user, project: other_project}
    other_history = history(other_ctx, task(other_ctx, "Other owner's history"))
    before = snapshot([unrelated, other_history])

    result = delete_task(ctx, tree.epic.task)
    assert result["errors"] == nil
    assert result["data"]["deleteTask"]["id"] == tree.epic.task.id
    Enum.each(Map.values(tree), &assert_deleted/1)
    assert Repo.get(TaskDependency, inbound.id) == nil
    assert Repo.get(TaskDependency, outbound.id) == nil
    assert Repo.get(TaskDependency, retained_edge.id) == retained_edge
    assert Repo.get(Artifact, artifact.id) == artifact
    assert snapshot([unrelated, other_history]) == before
  end

  test "deeper and branched completed run lineage deletes", ctx do
    tree = tree(ctx)

    deep =
      history(
        ctx,
        task(ctx, "Great grandchild", tree.grandchild.task),
        tree.grandchild,
        tree.epic
      )

    branch = history(ctx, task(ctx, "Branch", tree.epic.task), tree.epic, tree.epic)
    leaf = history(ctx, task(ctx, "Branch leaf", branch.task), branch, tree.epic)

    assert {:ok, _} = Tasks.delete(tree.epic.task)
    Enum.each([deep, branch, leaf | Map.values(tree)], &assert_deleted/1)
  end

  test "non-cascade preserves descendant history and clears deleted lineage references", ctx do
    tree = tree(ctx)
    unrelated = history(ctx, task(ctx, "Unrelated"))
    before = snapshot([unrelated])

    result = delete_task(ctx, tree.epic.task, false)
    assert result["errors"] == nil
    assert_deleted(tree.epic)
    assert Repo.get!(Task, tree.child.task.id).parent_id == nil
    assert Repo.get!(Task, tree.grandchild.task.id).parent_id == tree.child.task.id
    assert_preserved_history(tree.child, nil, nil, nil)
    assert_preserved_history(tree.grandchild, tree.child.run.id, nil, tree.child.execution.id)
    assert snapshot([unrelated]) == before
  end

  test "deleting an inner subtree retains surviving root history and external child runs", ctx do
    tree = tree(ctx)
    external = history(ctx, task(ctx, "External"), tree.child, tree.epic)
    before = snapshot([tree.epic])

    result = delete_task(ctx, tree.child.task)
    assert result["errors"] == nil
    assert_deleted(tree.child)
    assert_deleted(tree.grandchild)
    assert snapshot([tree.epic]) == before
    assert_preserved_history(external, nil, tree.epic.run.id, nil)
  end

  test "external parent and root-only lineage links preserve their owned history", ctx do
    tree = tree(ctx)
    external = history(ctx, task(ctx, "External"), tree.child, tree.epic)
    root_only = history(ctx, task(ctx, "Root-only link"), nil, tree.epic)
    external_child = history(ctx, task(ctx, "External child"), external, tree.epic)
    artifact = shared_artifact(ctx, tree.epic.task, external.task)

    assert {:ok, _} = Tasks.delete(tree.epic.task)
    Enum.each(Map.values(tree), &assert_deleted/1)
    assert_preserved_history(external, nil, nil, nil)
    assert_preserved_history(root_only, nil, nil, nil)
    assert_preserved_history(external_child, external.run.id, nil, external.execution.id)
    assert Repo.get(Artifact, artifact.id) == artifact
  end

  for {count, linked} <- [{1, false}, {2, true}, {3, false}] do
    test "deletes #{count} levels with linked=#{linked} runs", ctx do
      records =
        Enum.reduce(1..unquote(count), [], fn level, records ->
          parent = List.first(records)
          parent_task = if parent, do: parent.task
          task = task(ctx, "Level #{level}", parent_task)
          run_parent = if unquote(linked), do: parent
          root = if unquote(linked), do: List.last(records)
          [history(ctx, task, run_parent, root) | records]
        end)

      root = List.last(records)
      assert {:ok, _} = Tasks.delete(root.task)
      Enum.each(records, &assert_deleted/1)
    end
  end

  test "GraphQL database failure rolls back child detachment and all history", ctx do
    tree = tree(ctx)
    block_deletion(tree.epic.task, "NO ACTION")
    before = snapshot(Map.values(tree))

    result = delete_task(ctx, tree.epic.task, false)
    assert result["data"]["deleteTask"] == nil

    assert [%{"message" => "cannot delete task because its history is still referenced"}] =
             result["errors"]

    assert snapshot(Map.values(tree)) == before
  end

  test "repository non-cascade database failure is atomic and handled", ctx do
    tree = tree(ctx)
    block_deletion(tree.epic.task)
    before = snapshot(Map.values(tree))

    assert {:error, :delete_conflict} = TasksRepo.delete(tree.epic.task, cascade: false)
    assert snapshot(Map.values(tree)) == before
  end

  test "cascading database failure also preserves hierarchy and history", ctx do
    tree = tree(ctx)
    block_deletion(tree.grandchild.task)
    before = snapshot(Map.values(tree))

    result = delete_task(ctx, tree.epic.task)
    assert result["data"]["deleteTask"] == nil
    assert [%{"message" => _}] = result["errors"]
    assert snapshot(Map.values(tree)) == before
  end

  for status <- [:queued, :executing, :waiting, :stopping] do
    test "rejects deletion with #{status} owned runs before child detachment", ctx do
      tree = tree(ctx)
      {:ok, _} = TaskRuns.update(tree.epic.run, %{status: unquote(status)})
      before = snapshot(Map.values(tree))

      result = delete_task(ctx, tree.epic.task, false)
      assert result["data"]["deleteTask"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "stop the runs first"
      assert snapshot(Map.values(tree)) == before
    end
  end

  test "rejects cascade when a descendant owns an active run", ctx do
    tree = tree(ctx)
    {:ok, _} = TaskRuns.update(tree.grandchild.run, %{status: :executing})
    before = snapshot(Map.values(tree))

    assert {:error, message} = Tasks.delete(tree.epic.task)
    assert message =~ "stop the runs first"
    assert snapshot(Map.values(tree)) == before
  end

  test "rejects deleting ancestor history referenced by a surviving active run", ctx do
    tree = tree(ctx)
    external = history(ctx, task(ctx, "External"), tree.child, tree.epic)
    {:ok, _} = TaskRuns.update(external.run, %{status: :waiting})
    before = snapshot([external | Map.values(tree)])

    result = delete_task(ctx, tree.epic.task)
    assert result["data"]["deleteTask"] == nil
    assert [%{"message" => message}] = result["errors"]
    assert message =~ "stop the runs first"
    assert snapshot([external | Map.values(tree)]) == before
  end

  test "non-cascade can preserve independent active descendant runs", ctx do
    epic = history(ctx, task(ctx, "Epic"))
    child = history(ctx, task(ctx, "Independent child", epic.task))
    {:ok, _} = TaskRuns.update(child.run, %{status: :executing})
    before = Repo.get!(TaskRun, child.run.id)

    assert {:ok, _} = Tasks.delete(epic.task, cascade: false)
    assert_deleted(epic)
    assert Repo.get!(Task, child.task.id).parent_id == nil
    assert Repo.get!(TaskRun, child.run.id) == before
    assert Repo.get!(SessionLog, child.log.id) == child.log
  end

  test "missing and unauthorized task deletion returns handled errors", ctx do
    tree = tree(ctx)
    before = snapshot(Map.values(tree))
    other = create_user(%{email: "other@example.com", username: "other"})

    for {user, id} <- [{ctx.user, Ecto.UUID.generate()}, {other, tree.epic.task.id}] do
      result =
        ctx.conn
        |> authenticate(user)
        |> post("/graphql", %{"query" => ~s|mutation { deleteTask(id: "#{id}") { id } }|})
        |> json_response(200)

      assert result["data"]["deleteTask"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    assert snapshot(Map.values(tree)) == before
  end

  test "lineage still enforces foreign keys", ctx do
    task = task(ctx, "Invalid lineage")

    for field <- [:parent_task_run_id, :root_task_run_id] do
      assert {:error, changeset} =
               TaskRuns.insert(ctx.user.id, ctx.project.id, task.id, %{
                 field => Ecto.UUID.generate(),
                 :status => :completed
               })

      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "self-referencing root run deletes without dangling lineage", ctx do
    tree = tree(ctx)

    tree.epic.run
    |> TaskRun.lineage_changeset(%{root_task_run_id: tree.epic.run.id})
    |> Repo.update!()

    assert {:ok, _} = Tasks.delete(tree.epic.task)
    Enum.each(Map.values(tree), &assert_deleted/1)
  end

  defp tree(ctx) do
    epic = history(ctx, task(ctx, "Epic", nil, "epic"))
    child = history(ctx, task(ctx, "Child", epic.task, "ticket"), epic, epic)
    grandchild = history(ctx, task(ctx, "Grandchild", child.task), child, epic)
    %{epic: epic, child: child, grandchild: grandchild}
  end

  defp task(ctx, title, parent \\ nil, level \\ "task") do
    attrs = %{title: title, level: level, parent_id: if(parent, do: parent.id)}
    {:ok, task} = Tasks.insert(ctx.user.id, ctx.project.id, attrs)
    task
  end

  defp history(ctx, task, parent \\ nil, root \\ nil) do
    {:ok, run} =
      TaskRuns.insert(ctx.user.id, ctx.project.id, task.id, %{
        status: :completed,
        ended_at: DateTime.utc_now(),
        parent_task_run_id: if(parent, do: parent.run.id),
        root_task_run_id: if(root, do: root.run.id),
        triggered_by_step_execution_id: if(parent, do: parent.execution.id)
      })

    {:ok, execution} =
      StepExecutions.insert(ctx.user.id, %{
        task_id: task.id,
        project_id: ctx.project.id,
        task_run_id: run.id,
        step_name: "Completed step",
        status: "completed"
      })

    execution =
      execution
      |> Ecto.Changeset.change(
        conversation_root_execution_id: if(root, do: root.execution.id, else: execution.id),
        forked_from_execution_id: if(parent, do: parent.execution.id)
      )
      |> Repo.update!()

    {:ok, run} = TaskRuns.update(run, %{latest_step_execution_id: execution.id})
    scope = %{user_id: ctx.user.id, project_id: ctx.project.id}

    log =
      Repo.insert!(
        struct(
          SessionLog,
          Map.merge(scope, %{
            step_execution_id: execution.id,
            format: "harness",
            logical_key: "harness:deletion",
            content: "{}"
          })
        )
      )

    section =
      Repo.insert!(
        struct(
          TaskSection,
          Map.merge(scope, %{
            task_id: task.id,
            section_type: "goal",
            content: "Preserve ownership",
            section_order: 0
          })
        )
      )

    refs =
      for owner <- [%{task_id: task.id}, %{section_id: section.id}] do
        Repo.insert!(
          struct(
            CodeRef,
            Map.merge(scope, Map.merge(owner, %{path: "lib/example.ex", order_index: 0}))
          )
        )
      end

    %{task: task, run: run, execution: execution, log: log, section: section, refs: refs}
  end

  defp shared_artifact(ctx, deleted_task, surviving_task) do
    artifact =
      Repo.insert!(%Artifact{
        user_id: ctx.user.id,
        project_id: ctx.project.id,
        filename: "shared.md",
        body: "Keep me"
      })

    for task <- [deleted_task, surviving_task] do
      Repo.insert!(%ArtifactLink{
        artifact_id: artifact.id,
        user_id: ctx.user.id,
        project_id: ctx.project.id,
        subject_type: "task",
        subject_id: task.id
      })
    end

    artifact
  end

  defp delete_task(ctx, task, cascade \\ nil) do
    cascade_arg = if is_nil(cascade), do: "", else: ", cascade: #{cascade}"

    ctx.conn
    |> authenticate(ctx.user)
    |> post("/graphql", %{
      "query" => ~s|mutation { deleteTask(id: "#{task.id}"#{cascade_arg}) { id } }|
    })
    |> json_response(200)
  end

  defp assert_deleted(record) do
    for struct <- [
          record.task,
          record.run,
          record.execution,
          record.log,
          record.section | record.refs
        ] do
      assert Repo.get(struct.__struct__, struct.id) == nil
    end
  end

  defp assert_preserved_history(record, parent_id, root_id, trigger_id) do
    run = Repo.get!(TaskRun, record.run.id)

    assert run == %{
             record.run
             | parent_task_run_id: parent_id,
               root_task_run_id: root_id,
               triggered_by_step_execution_id: trigger_id
           }

    execution = Repo.get!(StepExecution, record.execution.id)
    expected_root = if root_id, do: record.execution.conversation_root_execution_id

    assert execution == %{
             record.execution
             | forked_from_execution_id: trigger_id,
               conversation_root_execution_id: expected_root
           }

    for struct <- [record.log, record.section | record.refs] do
      assert Repo.get!(struct.__struct__, struct.id) == struct
    end
  end

  defp snapshot(records) do
    Enum.flat_map(records, fn record ->
      for struct <- [
            record.task,
            record.run,
            record.execution,
            record.log,
            record.section | record.refs
          ] do
        Repo.get!(struct.__struct__, struct.id)
      end
    end)
  end

  defp block_deletion(task, on_delete \\ "RESTRICT") do
    # Sandbox-owned DDL and rows roll back after this synchronous test.
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE task_delete_blocker (
        task_id uuid REFERENCES tasks(id) ON DELETE #{on_delete}
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(Repo, "INSERT INTO task_delete_blocker VALUES ($1)", [
      Ecto.UUID.dump!(task.id)
    ])
  end
end
