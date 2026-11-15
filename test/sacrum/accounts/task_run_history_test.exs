defmodule Sacrum.Accounts.TaskRunHistoryTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Accounts.{Projects, TaskRuns, Tasks, Workflows}
  alias Sacrum.QueryCounter
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
  alias Sacrum.Repo.Users

  setup do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "History Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Delivery"})
    %{user: user, project: project, workflow: workflow}
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "run-history-#{suffix}@example.com",
        username: "runhistory#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user, project, workflow, attrs \\ %{}) do
    {:ok, task} =
      Tasks.insert(
        user.id,
        project.id,
        Map.merge(%{title: "History task"}, Map.take(attrs, [:title, :parent_id, :level]))
      )

    set =
      [workflow_id: workflow.id]
      |> Keyword.merge(Map.to_list(Map.take(attrs, [:archived, :completed_at])))

    Repo.update_all(where(Task, [t], t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  defp create_run(user, project, task, status, updated_at) do
    {:ok, run} = TaskRuns.insert(user.id, project.id, task.id, %{status: status})
    Repo.update_all(where(TaskRun, [tr], tr.id == ^run.id), set: [updated_at: updated_at])
    Repo.get!(TaskRun, run.id)
  end

  defp at(seconds), do: DateTime.add(~U[2026-11-15 06:00:00.000000Z], seconds, :second)

  defp history(user, project, opts \\ []) do
    {:ok, page} = TaskRuns.list_history_for_project(user.id, project.id, opts)
    page
  end

  defp run_ids(page), do: Enum.map(page.entries, & &1.task_run.id)

  test "pages runs newest update first and resumes strictly after the cursor", ctx do
    task = create_task(ctx.user, ctx.project, ctx.workflow)
    runs = for n <- 1..5, do: create_run(ctx.user, ctx.project, task, :failed, at(n))
    expected = runs |> Enum.reverse() |> Enum.map(& &1.id)

    first = history(ctx.user, ctx.project, limit: 2)
    assert run_ids(first) == Enum.take(expected, 2)
    assert first.has_more

    last = List.last(first.entries).task_run
    cursor = %{updated_at: last.updated_at, id: last.id}
    second = history(ctx.user, ctx.project, limit: 2, cursor: cursor)
    assert run_ids(second) == Enum.slice(expected, 2, 2)

    last = List.last(second.entries).task_run
    third = history(ctx.user, ctx.project, cursor: %{updated_at: last.updated_at, id: last.id})
    assert run_ids(third) == Enum.slice(expected, 4, 1)
    refute third.has_more
  end

  test "breaks updated_at ties by id so equal timestamps are never skipped", ctx do
    task = create_task(ctx.user, ctx.project, ctx.workflow)
    runs = for _ <- 1..3, do: create_run(ctx.user, ctx.project, task, :failed, at(1))
    expected = runs |> Enum.map(& &1.id) |> Enum.sort(:desc)

    first = history(ctx.user, ctx.project, limit: 1)
    last = hd(first.entries).task_run
    rest = history(ctx.user, ctx.project, cursor: %{updated_at: last.updated_at, id: last.id})

    assert run_ids(first) ++ run_ids(rest) == expected
  end

  test "carries the task labels and hierarchy the sidebar groups by", ctx do
    {:ok, epic} = Tasks.insert(ctx.user.id, ctx.project.id, %{title: "Epic", level: "epic"})

    task =
      create_task(ctx.user, ctx.project, ctx.workflow, %{title: "Child", parent_id: epic.id})

    create_run(ctx.user, ctx.project, task, :executing, at(1))

    assert [%{task: summary}] = history(ctx.user, ctx.project).entries

    assert summary == %{
             id: task.id,
             title: "Child",
             level: "task",
             parent_id: epic.id,
             workflow_id: ctx.workflow.id,
             workflow_name: "Delivery",
             completed_at: nil
           }
  end

  test "skips archived tasks, other projects and other users", ctx do
    visible = create_task(ctx.user, ctx.project, ctx.workflow)
    archived = create_task(ctx.user, ctx.project, ctx.workflow, %{archived: true})
    {:ok, other_project} = Projects.insert(ctx.user.id, %{name: "Other"})
    {:ok, other_workflow} = Workflows.insert(ctx.user.id, other_project.id, %{name: "Other"})
    elsewhere = create_task(ctx.user, other_project, other_workflow)

    run = create_run(ctx.user, ctx.project, visible, :executing, at(1))
    create_run(ctx.user, ctx.project, archived, :executing, at(2))
    create_run(ctx.user, other_project, elsewhere, :executing, at(4))

    assert run_ids(history(ctx.user, ctx.project, include_completed: true)) == [run.id]

    stranger = create_user()

    assert {:error, :not_found} =
             TaskRuns.list_history_for_project(stranger.id, ctx.project.id, [])
  end

  test "hides finished runs and completed tasks unless completed history is included", ctx do
    open = create_task(ctx.user, ctx.project, ctx.workflow)

    done =
      create_task(ctx.user, ctx.project, ctx.workflow, %{completed_at: at(0)})

    executing = create_run(ctx.user, ctx.project, open, :executing, at(5))
    failed = create_run(ctx.user, ctx.project, open, :failed, at(4))
    completed = create_run(ctx.user, ctx.project, open, :completed, at(3))
    stopped = create_run(ctx.user, ctx.project, open, :stopped, at(2))
    of_done = create_run(ctx.user, ctx.project, done, :failed, at(1))

    open_page = history(ctx.user, ctx.project)
    assert run_ids(open_page) == [executing.id, failed.id]
    # Completed tasks are not offered as hidden history, matching the sidebar.
    assert open_page.hidden_completed_count == 2

    all = history(ctx.user, ctx.project, include_completed: true)

    assert run_ids(all) == [executing.id, failed.id, completed.id, stopped.id, of_done.id]
    assert all.hidden_completed_count == 0
  end

  test "searches run id prefixes, task id prefixes and titles case-insensitively", ctx do
    alpha = create_task(ctx.user, ctx.project, ctx.workflow, %{title: "Alpha 100% done"})
    beta = create_task(ctx.user, ctx.project, ctx.workflow, %{title: "Beta"})
    alpha_run = create_run(ctx.user, ctx.project, alpha, :failed, at(2))
    beta_run = create_run(ctx.user, ctx.project, beta, :completed, at(1))

    search = &run_ids(history(ctx.user, ctx.project, include_completed: true, search: &1))

    assert search.("  ALPHA ") == [alpha_run.id]
    assert search.("100%") == [alpha_run.id]
    assert search.("0%") == [alpha_run.id]
    assert search.("_") == []
    assert search.(String.slice(beta_run.id, 0, 8)) == [beta_run.id]
    assert search.(String.upcase(String.slice(beta.id, 0, 8))) == [beta_run.id]
    assert search.("   ") == [alpha_run.id, beta_run.id]

    hidden = history(ctx.user, ctx.project, search: "beta")
    assert hidden.entries == []
    assert hidden.hidden_completed_count == 1
  end

  test "rejects out-of-range page sizes", ctx do
    for limit <- [0, TaskRuns.max_history_page_size() + 1, "10"] do
      assert {:error, :invalid_limit} =
               TaskRuns.list_history_for_project(ctx.user.id, ctx.project.id, limit: limit)
    end
  end

  test "a page costs a fixed number of statements however many tasks have runs", ctx do
    statements = fn task_count ->
      for _ <- 1..task_count do
        task = create_task(ctx.user, ctx.project, ctx.workflow)
        create_run(ctx.user, ctx.project, task, :executing, at(task_count))
      end

      {{:ok, _page}, statements} =
        QueryCounter.capture(fn ->
          TaskRuns.list_history_for_project(ctx.user.id, ctx.project.id, [])
        end)

      length(statements)
    end

    few = statements.(2)
    many = statements.(30)

    # Project ownership, the page, and the hidden-completed count.
    assert few == 3
    assert many == few
  end
end
