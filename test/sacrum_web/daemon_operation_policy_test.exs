defmodule SacrumWeb.DaemonOperationPolicyTest do
  use SacrumWeb.ConnCase, async: false
  import Phoenix.ChannelTest

  alias Sacrum.Accounts
  alias Sacrum.Auth
  alias Sacrum.Repo
  alias Sacrum.Repo.{Daemons, Projects, Tasks}
  alias Sacrum.Repo.Schemas.{Daemon, StepExecution}
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    owner = create_user()

    other =
      create_user(%{
        email: "other-policy@example.com",
        username: "otherpolicy",
        password: "password123"
      })

    {:ok, project} = Projects.insert(owner, %{name: "Owned"})
    {:ok, other_project} = Projects.insert(other, %{name: "Other"})
    {:ok, task} = Tasks.insert(other_project, %{title: "Protected task"})

    {:ok, execution} =
      Accounts.StepExecutions.insert(other.id, %{
        task_id: task.id,
        project_id: other_project.id,
        step_name: "execute",
        status: "running"
      })

    {:ok, daemon, bootstrap} = Daemons.create(owner.id)
    {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    {:ok, sibling, _} = Daemons.create(owner.id)
    {:ok, other_daemon, _} = Daemons.create(other.id)

    %{
      owner: owner,
      other: other,
      project: project,
      other_project: other_project,
      execution: execution,
      daemon: daemon,
      sibling: sibling,
      other_daemon: other_daemon,
      bootstrap: bootstrap,
      reconnect: reconnect
    }
  end

  test "daemon socket matrix permits only its own registration and no spoofed project membership",
       ctx do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(UserSocket, %{
        "daemon_id" => ctx.daemon.id,
        "reconnect_token" => ctx.reconnect
      })

    for daemon <- [ctx.sibling, ctx.other_daemon] do
      assert {:error, %{reason: "identity_mismatch"}} =
               subscribe_and_join(socket, "daemon:#{daemon.id}")
    end

    for project <- [ctx.project, ctx.other_project],
        client_type <- ["default", "daemon", "unknown"] do
      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, "project:#{project.id}", %{
                 "client_type" => client_type,
                 "user_id" => ctx.owner.id
               })
    end

    assert {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{ctx.daemon.id}")
    assert channel.assigns.daemon_id == ctx.daemon.id
    assert channel.assigns.user_id == ctx.owner.id
    assert Repo.get!(Daemon, ctx.other_daemon.id).status == "pending"
  end

  test "all standalone reporting and execution events are explicitly unsupported", ctx do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(UserSocket, %{
        "daemon_id" => ctx.daemon.id,
        "reconnect_token" => ctx.reconnect
      })

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{ctx.daemon.id}")

    for event <- [
          "report",
          "complete_step",
          "update_step_execution",
          "create_session_log",
          "run_step",
          "cancel_step",
          "unknown"
        ] do
      ref =
        Phoenix.ChannelTest.push(channel, event, %{
          execution_id: ctx.execution.id,
          project_id: ctx.other_project.id,
          user_id: ctx.other.id,
          status: "completed"
        })

      assert_reply ref, :error, %{reason: "unsupported_operation"}
    end

    assert Repo.get!(StepExecution, ctx.execution.id).status == "running"
    assert Repo.get!(StepExecution, ctx.execution.id).output == nil
    assert Repo.get!(Daemon, ctx.daemon.id).status == "pending"
  end

  test "bootstrap and reconnect cannot authorize any account GraphQL operation", ctx do
    operations = [
      "{ projects { id } }",
      "mutation { createDaemon { daemon { id } } }",
      "mutation { revokeDaemon(id: \"#{ctx.other_daemon.id}\") { id } }",
      "mutation { updateStepExecution(id: \"#{ctx.execution.id}\", status: \"completed\") { id } }",
      "mutation { createProject(name: \"Forbidden\") { id } }"
    ]

    for token <- [ctx.bootstrap, ctx.reconnect], query <- operations do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/graphql", %{query: query})

      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
    end

    assert Repo.get!(StepExecution, ctx.execution.id).status == "running"
    assert Repo.get!(Daemon, ctx.other_daemon.id).status == "pending"
    assert Enum.map(Accounts.Projects.list_by(ctx.owner.id), & &1.id) == [ctx.project.id]
  end

  test "legitimate account callers retain their project and GraphQL access", ctx do
    {:ok, account_token, _} = Auth.create_api_token(ctx.owner, %{name: "policy test"})
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, %{"token" => account_token})

    for client_type <- ["default", "daemon"] do
      assert {:ok, _, channel} =
               subscribe_and_join(socket, "project:#{ctx.project.id}", %{
                 "client_type" => client_type
               })

      assert channel.assigns.current_user.id == ctx.owner.id
      monitor = Process.monitor(channel.channel_pid)
      leave(channel)
      assert_receive {:DOWN, ^monitor, :process, _, _}
    end

    assert {:error, %{reason: "not found"}} =
             subscribe_and_join(socket, "project:#{ctx.other_project.id}")

    conn =
      build_conn() |> authenticate(ctx.owner) |> post("/graphql", %{query: "{ projects { id } }"})

    assert json_response(conn, 200)["data"]["projects"] == [%{"id" => ctx.project.id}]

    created =
      build_conn()
      |> authenticate(ctx.owner)
      |> post("/graphql", %{query: "mutation { createProject(name: \"Allowed\") { id name } }"})
      |> json_response(200)

    assert created["data"]["createProject"]["name"] == "Allowed"
    id = created["data"]["createProject"]["id"]
    assert {:ok, project} = Accounts.Projects.get_by(ctx.owner.id, conditions: [id: id])
    assert project.user_id == ctx.owner.id
  end
end
