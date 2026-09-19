defmodule SacrumWeb.DaemonChannelTest do
  use Sacrum.DataCase, async: false

  import Phoenix.ChannelTest

  alias Sacrum.Auth
  alias Sacrum.Accounts
  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo.Users
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp setup_daemon(suffix \\ "channel") do
    {:ok, user} =
      Users.insert(%{
        email: "daemon-#{suffix}@example.com",
        username: "daemon#{suffix}",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Sacrum.Accounts.Daemons.create(user.id)

    {:ok, daemon, token, _credential} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, socket} = connect(UserSocket, %{"token" => api_token(user)})
    {user, daemon, token, socket}
  end

  defp api_token(user) do
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "daemon channel test"})
    token
  end

  test "registers a valid daemon and cleans up on disconnect" do
    {_user, daemon, token, socket} = setup_daemon()

    assert {:ok, _reply, channel} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{"enrollment_token" => token})

    assert channel.assigns.daemon_id == daemon.id
    assert channel.assigns.user_id == daemon.user_id
    assert is_binary(channel.assigns.credential_id)

    assert [{_pid, %{user_id: user_id, credential_id: credential_id}}] =
             Sacrum.DaemonConnectionRegistry.lookup(daemon.id)

    assert user_id == daemon.user_id
    assert credential_id == channel.assigns.credential_id

    ref = Process.monitor(channel.channel_pid)
    leave(channel)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "committed unregister terminates the connected standalone session" do
    {user, daemon, token, _} = setup_daemon("unregister_live")

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    assert {:ok, deleted} = Sacrum.Accounts.Daemons.unregister(user.id, daemon.id)
    assert deleted.status == "active"

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []

    assert :error =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
  end

  test "rotation terminates only affected sessions; siblings survive and exchange reconnects" do
    {user, daemon, token, _} = setup_daemon("rotate_live")

    {:ok, sibling, sibling_bootstrap} = Sacrum.Accounts.Daemons.create(user.id)

    {:ok, _, sibling_token, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(sibling.id, sibling_bootstrap)

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    {:ok, sibling_socket} =
      connect(UserSocket, %{"daemon_id" => sibling.id, "reconnect_token" => sibling_token})

    {:ok, _, sibling_channel} = subscribe_and_join(sibling_socket, "daemon:#{sibling.id}")
    sibling_monitor = Process.monitor(sibling_channel.channel_pid)

    assert {:ok, _, new_bootstrap, _} =
             Sacrum.Accounts.Daemons.rotate_bootstrap(user.id, daemon.id)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []

    ref = Phoenix.ChannelTest.push(sibling_channel, "report", %{})
    assert_reply ref, :error, %{reason: "invalid_report"}
    refute_received {:DOWN, ^sibling_monitor, :process, _, _}

    {:ok, _, fresh_reconnect, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, new_bootstrap)

    {:ok, fresh_socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => fresh_reconnect})

    assert {:ok, _, fresh_channel} = subscribe_and_join(fresh_socket, "daemon:#{daemon.id}")
    assert fresh_channel.assigns.daemon_id == daemon.id
    leave(sibling_channel)
  end

  test "delayed invalidation cannot terminate a newer valid session" do
    {user, daemon, token, _} = setup_daemon("stale_invalidation")

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    assert {:ok, _, new_bootstrap, _} =
             Sacrum.Accounts.Daemons.rotate_bootstrap(user.id, daemon.id)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    {:ok, _, fresh_reconnect, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, new_bootstrap)

    {:ok, fresh_socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => fresh_reconnect})

    {:ok, _, fresh_channel} = subscribe_and_join(fresh_socket, "daemon:#{daemon.id}")
    fresh_monitor = Process.monitor(fresh_channel.channel_pid)

    send(fresh_channel.channel_pid, :daemon_credentials_invalidated)

    ref = Phoenix.ChannelTest.push(fresh_channel, "report", %{})
    assert_reply ref, :error, %{reason: "invalid_report"}
    refute_received {:DOWN, ^fresh_monitor, :process, _, _}
  end

  test "rejects a credential belonging to another daemon" do
    {_user, daemon, _token, socket} = setup_daemon("first")
    {_other_user, _other_daemon, other_token, _other_socket} = setup_daemon("second")

    assert {:error, %{reason: "invalid_credentials"}} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{
               "enrollment_token" => other_token
             })
  end

  test "standalone session owns registration and duplicate failure cannot release it" do
    {user, daemon, token, _} = setup_daemon("standalone")

    assert {:ok, socket} =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:ok, _, channel} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{
               "user_id" => Ecto.UUID.generate()
             })

    assert channel.assigns.user_id == user.id
    refute Map.has_key?(channel.assigns, :current_user)
    owner = channel.channel_pid
    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)

    assert {:ok, duplicate} =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:error, %{reason: "already_connected"}} =
             subscribe_and_join(duplicate, "daemon:#{daemon.id}")

    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    :ok = Sacrum.DaemonConnectionRegistry.unregister(daemon.id)
    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    monitor = Process.monitor(owner)
    leave(channel)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    assert {:ok, _, rejoined} = subscribe_and_join(duplicate, "daemon:#{daemon.id}")
    assert rejoined.assigns.daemon_id == daemon.id
  end

  test "standalone topic identity is exact and project channels remain forbidden" do
    {_user, daemon, token, _} = setup_daemon("topics")
    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:error, %{reason: "identity_mismatch"}} =
             subscribe_and_join(socket, "daemon:#{Ecto.UUID.generate()}")

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "project:#{Ecto.UUID.generate()}")

    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "join rechecks unregister and rotation since socket authentication" do
    for action <- [:rotate, :unregister] do
      {user, daemon, token, _} = setup_daemon("recheck#{action}")
      {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
      apply(Sacrum.Accounts.Daemons, action, [user.id, daemon.id])

      assert {:error, %{reason: "invalid_credentials"}} =
               subscribe_and_join(socket, "daemon:#{daemon.id}")

      assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    end
  end

  test "reconnect survives bootstrap expiry and channel process restart" do
    {_user, daemon, token, _} = setup_daemon("restart")

    Repo.update_all(
      from(c in Sacrum.Repo.Schemas.DaemonCredential,
        where: c.daemon_id == ^daemon.id and c.credential_kind == "bootstrap"
      ),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)
    close(channel)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    {:ok, fresh} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
    assert {:ok, _, restarted} = subscribe_and_join(fresh, "daemon:#{daemon.id}")
    assert restarted.assigns.daemon_id == daemon.id
  end

  test "join refuses reconnect that expired after socket authentication" do
    {_user, daemon, token, _} = setup_daemon("expiry")
    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    Repo.update_all(
      from(c in Sacrum.Repo.Schemas.DaemonCredential,
        where: c.id == ^socket.assigns.principal.credential_id
      ),
      set: [expires_at: DateTime.utc_now()]
    )

    assert {:error, %{reason: "invalid_credentials"}} =
             subscribe_and_join(socket, "daemon:#{daemon.id}")

    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "accepts authenticated reports and heartbeat liveness on the daemon topic" do
    {user, daemon, token, socket} = setup_daemon("report")

    {:ok, _, channel} =
      subscribe_and_join(socket, "daemon:#{daemon.id}", %{
        "enrollment_token" => token
      })

    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "account:#{user.id}")

    report = %{
      "version" => 1,
      "daemon_id" => daemon.id,
      "daemon_version" => "v1.2.3",
      "os" => "linux",
      "architecture" => "x86_64",
      "host" => "builder-1",
      "started_at" => "2026-09-17T10:00:00Z",
      "capabilities" => %{"providers" => %{"openai" => true}},
      "token_hash" => "must-not-be-stored",
      "project_ids" => [Ecto.UUID.generate()]
    }

    ref = Phoenix.ChannelTest.push(channel, "report", report)
    assert_reply ref, :ok, %{accepted: true, report_version: 1}

    user_id = user.id
    daemon_id = daemon.id
    metrics = Sacrum.DaemonConnectionRegistry.metrics(daemon.id)
    assert metrics.daemon_version == "v1.2.3"
    assert metrics.connection_status == "online"
    assert metrics.health == "healthy"
    refute inspect(metrics) =~ "must-not-be-stored"
    refute inspect(metrics) =~ "project_ids"

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "account:" <> ^user_id,
      event: "daemon_metrics",
      payload: %{id: ^daemon_id, health: "healthy"}
    }

    ref = Phoenix.ChannelTest.push(channel, "heartbeat", %{})
    assert_reply ref, :ok, %{accepted: true, report_version: 1}

    metrics = Sacrum.DaemonConnectionRegistry.metrics(daemon.id)
    assert metrics.last_seen_at
    assert metrics.report_version == 1
  end

  test "rejects spoofed, unsupported, and empty reports without updating metrics" do
    {_user, daemon, token, socket} = setup_daemon("invalid_report")
    {_other_user, other_daemon, _other_token, _other_socket} = setup_daemon("spoofed_report")

    {:ok, _, channel} =
      subscribe_and_join(socket, "daemon:#{daemon.id}", %{
        "enrollment_token" => token
      })

    for payload <- [
          %{"version" => 1, "daemon_id" => other_daemon.id},
          %{"version" => 2},
          %{}
        ] do
      ref = Phoenix.ChannelTest.push(channel, "report", payload)
      assert_reply ref, :error, %{reason: "invalid_report"}
    end

    assert Sacrum.DaemonConnectionRegistry.metrics(daemon.id) == nil
  end

  test "delivers a run command only to the assigned daemon" do
    {user, daemon, token, socket} = setup_daemon("execution_delivery")

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Execution Delivery"})

    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{name: "Execution Workflow"})

    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "name" => "Execute",
        "step_order" => 1,
        "workflow_id" => workflow.id,
        "project_id" => project.id,
        "prompt" => "Run the assigned work"
      })

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Execution Task",
        workflow_id: workflow.id,
        workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/execution"}
      })

    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        task_run_id: task_run.id,
        project_id: project.id,
        workflow_id: workflow.id,
        step_id: step.id,
        step_name: step.name,
        status: "started",
        prompt: step.prompt
      })

    {:ok, _reply, _channel} =
      subscribe_and_join(socket, "daemon:#{daemon.id}", %{"enrollment_token" => token})

    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{daemon.id}")

    data = %{task: task, step: step, execution: execution, rendered_prompt: step.prompt}
    assert :ok = CommandBroadcaster.broadcast_run_step(data, daemon.id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "daemon:" <> _,
      event: "run_step",
      payload: %{id: execution_id, project_id: project_id}
    }

    assert execution_id == execution.id
    assert project_id == project.id
  end
end
