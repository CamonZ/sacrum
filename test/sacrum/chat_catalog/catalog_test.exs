defmodule Sacrum.ChatCatalog.CatalogTest do
  use Sacrum.DataCase, async: true
  alias Sacrum.Accounts.{ChatCatalog, Projects, Tasks}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatCatalogEntry, TaskRun, StepExecution}

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "chat#{n}@example.com",
        username: "chat#{n}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "Catalog"})
    {:ok, project2} = Projects.insert(user.id, %{name: "Other"})
    machine = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(user.id, machine)
    %{u: user.id, p: project.id, p2: project2.id, m: machine}
  end

  defp put(c, chat, rev, payload, mutation \\ Ecto.UUID.generate()),
    do: ChatCatalog.put(c.u, c.p, c.m, chat, rev, mutation, payload)

  test "activity status roundtrips independently of open/closed metadata and rejects invalid values",
       c do
    {:ok, %{entry: first}} = put(c, "activity", 0, %{"metadata" => %{"status" => "open"}})
    assert first.status == :idle

    Enum.reduce(1..40, first, fn n, previous ->
      status = if rem(n, 2) == 0, do: "idle", else: "working"
      {:ok, %{entry: entry}} = put(c, "activity", previous.revision, %{"status" => status})
      assert ChatCatalogEntry.payload(Repo.get!(ChatCatalogEntry, entry.id))["status"] == status
      assert entry.metadata["status"] == "open"
      assert entry.revision == previous.revision + 1
      entry
    end)

    for invalid <- [nil, true, "busy", "open", []] do
      assert {:error, "invalid catalog payload"} =
               put(c, "invalid-status", 0, %{"status" => invalid})
    end

    {:ok, id} = Ecto.UUID.dump(first.id)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn -> Repo.query!("UPDATE chat_catalog_entries SET status='busy' WHERE id=$1", [id]) end,
        mode: :savepoint
      )
    end
  end

  test "seeded generated owner/project/machine combinations obey independent set oracle and stable pagination",
       c do
    :rand.seed(:exsss, {297, 44, 8})

    machines =
      for _ <- 1..3 do
        id = Ecto.UUID.generate()
        {:ok, _} = ChatCatalog.register(c.u, id)
        id
      end

    expected =
      for n <- 1..90 do
        m = Enum.at(machines, :rand.uniform(3) - 1)
        p = Enum.at([c.p, c.p2], :rand.uniform(2) - 1)
        id = "chat-#{n}"

        {:ok, %{status: "accepted", entry: row}} =
          put(%{c | p: p, m: m}, id, 0, %{
            "metadata" => %{"title" => id, "createdAt" => "2026-01-01T00:00:00Z"}
          })

        Repo.update_all(from(e in ChatCatalogEntry, where: e.id == ^row.id),
          set: [inserted_at: ~U[2026-01-01 00:00:00.000000Z]]
        )

        {m, p, id}
      end

    for m <- machines, p <- [c.p, c.p2] do
      oracle =
        expected
        |> Enum.filter(fn {machine, project, _} -> machine == m and project == p end)
        |> Enum.map(&elem(&1, 2))
        |> Enum.sort()

      assert page_all(c.u, p, m, nil, []) == oracle
    end

    assert {:ok, %{entries: []}} = ChatCatalog.list(c.u, c.p, Ecto.UUID.generate())

    assert {:ok, %{entries: []}} =
             ChatCatalog.list(Ecto.UUID.generate(), c.p, c.m)
  end

  defp page_all(u, p, m, cursor, acc, include_completed \\ false, page_size \\ 3) do
    {:ok, page} = ChatCatalog.list(u, p, m, cursor, page_size, include_completed)
    next = acc ++ Enum.map(page.entries, & &1.chat_id)

    if page.next_cursor do
      assert next != acc
      assert page.next_cursor != cursor
      page_all(u, p, m, page.next_cursor, next, include_completed, page_size)
    else
      next
    end
  end

  test "completed-task filtering precedes pagination and opt-in returns the whole catalog", c do
    cases =
      for n <- 0..11 do
        id = String.pad_leading(Integer.to_string(n), 2, "0")
        linked? = rem(n, 4) != 0
        completed? = linked? and rem(n, 2) == 0

        task_id =
          if linked? do
            level = Enum.at(["epic", "ticket", "task"], rem(n, 3))
            {:ok, task} = Tasks.insert(c.u, c.p, %{title: id, level: level})

            Repo.update!(
              Ecto.Changeset.change(task,
                completed_at: if(completed?, do: DateTime.utc_now()),
                archived: rem(n, 5) == 0
              )
            )

            task.id
          end

        {:ok, _} = put(c, id, 0, %{"task_id" => task_id})
        {id, completed?}
      end

    for include_completed <- [false, true], page_size <- [1, 2, 3, 9, 12, 20] do
      expected = for {id, completed?} <- cases, include_completed or not completed?, do: id
      assert page_all(c.u, c.p, c.m, nil, [], include_completed, page_size) == expected
    end

    assert length(Sacrum.Repo.ChatCatalog.list(c.u, c.p, c.m, nil, 100)) == 9
    assert length(Sacrum.Repo.ChatCatalog.list(c.u, c.p, c.m, nil, 100, true)) == 12

    assert {:error, "include_completed must be a boolean"} =
             ChatCatalog.list(c.u, c.p, c.m, nil, 100, nil)

    # Task completion is reversible; no catalog mutation is required to reveal it again.
    Repo.update_all(from(t in Sacrum.Repo.Schemas.Task, where: t.project_id == ^c.p),
      set: [completed_at: nil]
    )

    assert page_all(c.u, c.p, c.m, nil, []) == Enum.map(cases, &elem(&1, 0))
  end

  test "generated existing owner/project combinations follow independent ownership oracle", c do
    owners =
      for n <- 1..3 do
        suffix = System.unique_integer([:positive])

        {:ok, user} =
          Sacrum.Repo.Users.insert(%{
            email: "owner#{suffix}@example.com",
            username: "owner#{suffix}",
            password: "password123"
          })

        projects =
          for index <- 1..2 do
            {:ok, project} = Projects.insert(user.id, %{name: "#{n}-#{index}"})
            project.id
          end

        {user.id, projects}
      end

    machines = for _ <- 1..2, do: Ecto.UUID.generate()

    all_projects =
      Enum.flat_map(owners, fn {owner, projects} -> Enum.map(projects, &{owner, &1}) end)

    for {user, _} <- owners, machine <- machines do
      {:ok, _} = ChatCatalog.register(user, machine)

      for {owner, project} <- all_projects do
        result = put(%{c | u: user, p: project, m: machine}, project, 0, %{})

        if owner == user do
          assert {:ok,
                  %{entry: %{user_id: ^user, project_id: ^project, installation_id: ^machine}}} =
                   result

          assert {:ok, %{entries: [%{chat_id: ^project}]}} =
                   ChatCatalog.list(user, project, machine)
        else
          assert {:error, %Ecto.Changeset{}} = result

          assert {:ok, %{entries: [], next_cursor: nil}} =
                   ChatCatalog.list(user, project, machine)
        end
      end
    end
  end

  test "reference CAS model survives generated stale/repeated writes and terminal tombstones",
       c do
    :rand.seed(:exsss, {8, 44, 297})
    events = for n <- 1..100, do: {n, if(n == 75, do: 3, else: :rand.uniform(5))}

    Enum.reduce(events, %{revision: 0, deleted: false, mutation: nil, title: nil}, fn {n, choice},
                                                                                      model ->
      revision = if choice == 1, do: max(0, model.revision - 1), else: model.revision
      mutation = if choice == 2 and model.mutation, do: model.mutation, else: Ecto.UUID.generate()
      deleted = n == 75
      title = "version-#{n}"
      accepted = model.mutation == mutation or (not model.deleted and revision == model.revision)

      {:ok, result} =
        put(
          c,
          "model",
          revision,
          %{"metadata" => %{"title" => title}, "deleted" => deleted},
          mutation
        )

      assert result.status == if(accepted, do: "accepted", else: "conflict")

      next =
        if accepted and model.mutation != mutation,
          do: %{revision: model.revision + 1, deleted: deleted, mutation: mutation, title: title},
          else: model

      assert result.entry.revision == next.revision
      assert result.entry.deleted == next.deleted
      assert result.entry.metadata["title"] == next.title
      persisted = Repo.get!(ChatCatalogEntry, result.entry.id)

      assert {persisted.revision, persisted.deleted, persisted.metadata["title"]} ==
               {next.revision, next.deleted, next.title}

      next
    end)
  end

  test "classifications including empty decisions roundtrip exactly and reject nested local fields",
       c do
    for n <- 0..50 do
      labels = if rem(n, 2) == 0, do: [], else: ["custom category #{n}", "自由なラベル", "file edits"]
      hash = :crypto.hash(:sha256, "#{n}") |> Base.encode16(case: :lower)

      classifications = [
        %{
          "tool_id" => hash,
          "input_hash" => hash,
          "classifier_fingerprint" => hash,
          "labels" => labels
        }
      ]

      payload = %{"metadata" => %{}, "classifications" => classifications}

      {:ok, %{entry: entry}} =
        put(c, "class-#{n}", 0, payload |> Jason.encode!() |> Jason.decode!())

      assert Repo.get!(ChatCatalogEntry, entry.id).classifications == classifications

      for key <- [
            "patch",
            "worktreePath",
            "gitFiles",
            "command",
            "input",
            "result",
            "association"
          ] do
        assert {:error, "invalid catalog payload"} =
                 put(c, "bad", 0, Map.put(payload, key, "SECRET"))

        assert {:error, "invalid catalog payload"} =
                 put(c, "bad", 0, Map.put(payload, "metadata", %{key => "SECRET"}))

        assert {:error, "invalid catalog payload"} =
                 put(
                   c,
                   "bad",
                   0,
                   Map.put(payload, "classifications", [
                     Map.put(hd(classifications), key, "SECRET")
                   ])
                 )
      end
    end
  end

  test "database constraints guard task/gate/parent scope through direct repo paths", c do
    for level <- ["epic", "ticket", "task"] do
      {:ok, task} = Tasks.insert(c.u, c.p, %{title: level, level: level})
      assert {:ok, %{entry: entry}} = put(c, level, 0, %{"task_id" => task.id})
      assert entry.task_id == task.id
    end

    {:ok, foreign} = Tasks.insert(c.u, c.p2, %{title: "Foreign", level: "task"})

    for id <- [foreign.id, Ecto.UUID.generate()] do
      assert {:error, changeset} = put(c, "invalid", 0, %{"task_id" => id})
      assert errors_on(changeset).task_id == ["does not exist"]
    end

    {:ok, %{entry: row}} = put(c, "direct", 0, %{})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn -> Repo.update!(Ecto.Changeset.change(row, task_id: foreign.id)) end,
        mode: :savepoint
      )
    end

    assert {:error, changeset} = put(c, "missing-parent", 0, %{"parent_chat_id" => "absent"})
    assert errors_on(changeset).parent_chat_id == ["does not exist"]
    {:ok, _} = put(%{c | p: c.p2}, "foreign-parent", 0, %{})
    assert {:error, _} = put(c, "child", 0, %{"parent_chat_id" => "foreign-parent"})
    {:ok, _} = put(c, "parent", 0, %{})
    assert {:ok, _} = put(c, "child", 0, %{"parent_chat_id" => "parent"})

    for field <- ["gate_execution_id", "gate_task_run_id"] do
      assert {:error, changeset} = put(c, "gate", 0, %{field => Ecto.UUID.generate()})

      assert Map.fetch!(errors_on(changeset), String.to_existing_atom(field)) == [
               "does not exist"
             ]
    end

    {:ok, foreign_task} = Tasks.insert(c.u, c.p2, %{title: "Gate", level: "task"})

    run =
      Repo.insert!(%TaskRun{
        user_id: c.u,
        project_id: c.p2,
        task_id: foreign_task.id,
        status: :completed,
        started_at: DateTime.utc_now()
      })

    execution =
      Repo.insert!(%StepExecution{
        user_id: c.u,
        project_id: c.p2,
        task_id: foreign_task.id,
        task_run_id: run.id,
        step_name: "gate",
        status: "completed"
      })

    assert {:error, _} = put(c, "gate-run", 0, %{"gate_task_run_id" => run.id})
    assert {:error, _} = put(c, "gate-exec", 0, %{"gate_execution_id" => execution.id})

    assert {:ok, _} =
             put(%{c | p: c.p2}, "gate-valid", 0, %{
               "gate_task_run_id" => run.id,
               "gate_execution_id" => execution.id
             })
  end

  test "raw SQL rejects missing and foreign scoped links and task deletion clears the reference",
       c do
    {:ok, task} = Tasks.insert(c.u, c.p, %{title: "Linked", level: "ticket"})
    {:ok, foreign} = Tasks.insert(c.u, c.p2, %{title: "Foreign", level: "ticket"})
    {:ok, %{entry: row}} = put(c, "raw-sql", 0, %{"task_id" => task.id})
    {:ok, row_id} = Ecto.UUID.dump(row.id)
    n = System.unique_integer([:positive])

    {:ok, other_user} =
      Sacrum.Repo.Users.insert(%{
        email: "foreign-chat#{n}@example.com",
        username: "foreignchat#{n}",
        password: "password123"
      })

    {:ok, _} = ChatCatalog.register(other_user.id, c.m)
    {:ok, foreign_owner} = Ecto.UUID.dump(other_user.id)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE chat_catalog_entries SET user_id=$1 WHERE id=$2", [
            foreign_owner,
            row_id
          ])
        end,
        mode: :savepoint
      )
    end

    machine2 = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(c.u, machine2)
    {:ok, _} = put(%{c | m: machine2}, "other-machine-parent", 0, %{})

    assert {:error, _} =
             put(c, "child-other-machine", 0, %{"parent_chat_id" => "other-machine-parent"})

    for column <- ["task_id", "gate_execution_id", "gate_task_run_id"],
        id <- [foreign.id, Ecto.UUID.generate()] do
      {:ok, binary} = Ecto.UUID.dump(id)

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.query!("UPDATE chat_catalog_entries SET #{column}=$1 WHERE id=$2", [
              binary,
              row_id
            ])
          end,
          mode: :savepoint
        )
      end
    end

    for column <- ["project_id", "user_id", "installation_id"] do
      {:ok, invalid} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.query!("UPDATE chat_catalog_entries SET #{column}=$1 WHERE id=$2", [
              invalid,
              row_id
            ])
          end,
          mode: :savepoint
        )
      end
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE chat_catalog_entries SET parent_chat_id='missing' WHERE id=$1", [
            row_id
          ])
        end,
        mode: :savepoint
      )
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(
        fn ->
          Repo.insert!(%ChatCatalogEntry{
            user_id: c.u,
            project_id: c.p,
            installation_id: c.m,
            chat_id: "raw-insert",
            task_id: foreign.id,
            mutation_id: Ecto.UUID.generate()
          })
        end,
        mode: :savepoint
      )
    end

    assert {:ok, _} = Repo.delete(task)
    cleared = Repo.get!(ChatCatalogEntry, row.id)
    assert cleared.task_id == nil
    assert cleared.revision > row.revision
    assert {cleared.user_id, cleared.project_id, cleared.installation_id} == {c.u, c.p, c.m}

    assert {:ok, %{status: "conflict", entry: %{task_id: nil}}} =
             put(c, "raw-sql", row.revision, %{"task_id" => task.id})

    assert {:ok, _} = Projects.delete(Sacrum.Repo.get!(Sacrum.Repo.Schemas.Project, c.p))
    assert Repo.get(ChatCatalogEntry, row.id) == nil
  end

  test "normal association writes advance the revision exactly once", c do
    {:ok, task} = Tasks.insert(c.u, c.p, %{title: "Associate"})
    {:ok, %{entry: first}} = put(c, "revision", 0, %{})
    {:ok, %{entry: linked}} = put(c, "revision", first.revision, %{"task_id" => task.id})
    assert linked.revision == first.revision + 1
    {:ok, %{entry: cleared}} = put(c, "revision", linked.revision, %{"task_id" => nil})
    assert cleared.revision == linked.revision + 1
  end

  test "deleting individual gate history clears only its own reference", c do
    history = task_history(c, "task")

    {:ok, %{entry: entry}} =
      put(c, "gate-cleanup", 0, %{
        "task_id" => history.task.id,
        "gate_execution_id" => history.execution.id,
        "gate_task_run_id" => history.run.id
      })

    Repo.delete!(history.run)
    after_run = Repo.get!(ChatCatalogEntry, entry.id)
    assert after_run.gate_task_run_id == nil
    assert after_run.task_id == history.task.id
    assert after_run.gate_execution_id == history.execution.id
    assert after_run.revision == entry.revision + 1
    assert DateTime.compare(after_run.updated_at, entry.updated_at) == :gt

    Repo.delete!(Repo.get!(StepExecution, history.execution.id))
    after_execution = Repo.get!(ChatCatalogEntry, entry.id)
    assert after_execution.gate_execution_id == nil
    assert after_execution.task_id == history.task.id
    assert after_execution.revision == after_run.revision + 1
  end

  test "generated task deletions clear only links to deleted records and preserve chat contents",
       c do
    for level <- ["epic", "ticket", "task"], path <- [:sql, :repo], mask <- 0..7 do
      victim = task_history(c, level)
      survivor = task_history(c, "task")

      # Each bit independently chooses a reference to the deleted task's
      # history or to surviving history in the same owner/project scope.
      targets =
        for {field, bit, source} <- [
              {"task_id", 1, :task},
              {"gate_execution_id", 2, :execution},
              {"gate_task_run_id", 4, :run}
            ],
            into: %{} do
          history = if Bitwise.band(mask, bit) == 0, do: survivor, else: victim
          {field, Map.fetch!(history, source).id}
        end

      content = %{"metadata" => %{"title" => "Preserve this chat"}, "classifications" => []}

      {:ok, %{entry: entry}} =
        put(c, "delete-#{level}-#{path}-#{mask}", 0, Map.merge(content, targets))

      case path do
        :sql ->
          {:ok, id} = Ecto.UUID.dump(victim.task.id)
          Repo.query!("DELETE FROM tasks WHERE id = $1", [id])

        :repo ->
          assert {:ok, _} = Sacrum.Repo.Tasks.delete(victim.task)
      end

      refreshed = Repo.get!(ChatCatalogEntry, entry.id)

      for {field, bit} <- [{:task_id, 1}, {:gate_execution_id, 2}, {:gate_task_run_id, 4}] do
        expected = if Bitwise.band(mask, bit) == 0, do: Map.fetch!(targets, Atom.to_string(field))
        assert Map.fetch!(refreshed, field) == expected
      end

      assert refreshed.metadata == entry.metadata
      assert refreshed.classifications == entry.classifications

      assert {refreshed.user_id, refreshed.project_id, refreshed.installation_id} ==
               {c.u, c.p, c.m}

      refute refreshed.deleted

      if mask == 0,
        do: assert(refreshed.revision == entry.revision),
        else: assert(refreshed.revision > entry.revision)
    end
  end

  defp task_history(c, level) do
    {:ok, task} = Tasks.insert(c.u, c.p, %{title: "History owner", level: level})

    run =
      Repo.insert!(%TaskRun{
        user_id: c.u,
        project_id: c.p,
        task_id: task.id,
        status: :completed,
        started_at: DateTime.utc_now()
      })

    execution =
      Repo.insert!(%StepExecution{
        user_id: c.u,
        project_id: c.p,
        task_id: task.id,
        task_run_id: run.id,
        step_name: "gate",
        status: "completed"
      })

    %{task: task, run: run, execution: execution}
  end

  test "catalog writes do not select tasks and installation registration is idempotent", c do
    {:ok, task} = Tasks.insert(c.u, c.p, %{title: "No preflight", level: "task"})
    pid = self()
    handler = "catalog-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:sacrum, :repo, :query],
      fn _, _, metadata, _ -> if self() == pid, do: send(pid, {:query, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, _} = put(c, "no-preflight", 0, %{"task_id" => task.id})
    queries = drain([])
    refute Enum.any?(queries, &Regex.match?(~r/SELECT.*FROM "tasks"/s, &1))

    assert {:ok, %{entries: [], next_cursor: nil}} =
             ChatCatalog.list(c.u, Ecto.UUID.generate(), c.m)

    queries = drain([])
    assert length(queries) == 1
    assert hd(queries) =~ ~s(FROM "chat_catalog_entries")
    refute Enum.any?(queries, &Regex.match?(~r/FROM "(?:projects|tasks)"/, &1))

    assert {:ok, %{user_id: owner}} = ChatCatalog.register(c.u, c.m)
    assert owner == c.u
  end

  defp drain(acc) do
    receive do
      {:query, q} -> drain([q | acc])
    after
      0 -> acc
    end
  end
end
