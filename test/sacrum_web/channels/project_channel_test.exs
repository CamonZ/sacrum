defmodule SacrumWeb.ProjectChannelTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest
  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
  alias Sacrum.Realtime.ProjectChannelCdcContract
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

  @endpoint SacrumWeb.Endpoint

  @valid_user_attrs %{
    email: "channel@example.com",
    username: "channeluser",
    password: "password123"
  }

  @project_attrs %{name: "Test Project"}

  defp setup_socket do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {:ok, project} = Projects.insert(user, @project_attrs)

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {user, project, socket}
  end

  describe "join/3" do
    test "can join project channel for owned project" do
      {_user, project, socket} = setup_socket()

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "project:#{project.id}")
      assert socket.assigns.project.id == project.id
    end

    test "cannot join channel for another user's project" do
      {_user, _project, socket} = setup_socket()

      # Create a project owned by a different user
      {:ok, other_user} =
        Users.insert(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other Project"})

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, "project:#{other_project.id}")
    end

    test "cannot join channel for nonexistent project" do
      {_user, _project, socket} = setup_socket()

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(socket, "project:#{Ecto.UUID.generate()}")
    end
  end

  describe "client_type assignment" do
    test "join with client_type=daemon assigns daemon to socket" do
      {_user, project, socket} = setup_socket()

      assert {:ok, _reply, socket} =
               subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      assert socket.assigns.client_type == "daemon"
    end

    test "join without client_type param defaults to default" do
      {_user, project, socket} = setup_socket()

      assert {:ok, _reply, socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      assert socket.assigns.client_type == "default"
    end

    test "join with invalid client_type param defaults to default" do
      {_user, project, socket} = setup_socket()

      assert {:ok, _reply, socket} =
               subscribe_and_join(socket, "project:#{project.id}", %{
                 "client_type" => "invalid_type"
               })

      assert socket.assigns.client_type == "default"
    end
  end

  describe "daemon registry integration" do
    test "joining as daemon registers presence for the project" do
      {_user, project, socket} = setup_socket()

      # Verify no daemon connected initially
      assert Sacrum.DaemonRegistry.daemon_connected?(project.id) == false

      # Join as daemon
      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      # Verify daemon is registered
      assert Sacrum.DaemonRegistry.daemon_connected?(project.id) == true
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 1
    end

    test "multiple daemons for the same project are tracked correctly" do
      {_user, project, _socket} = setup_socket()

      # No daemons initially
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 0

      # Register first daemon
      Sacrum.DaemonRegistry.register_daemon(project.id)
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 1

      # Register second daemon
      Sacrum.DaemonRegistry.register_daemon(project.id)
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 2

      # Unregister one
      Sacrum.DaemonRegistry.unregister_daemon(project.id)
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 1

      # Unregister the other
      Sacrum.DaemonRegistry.unregister_daemon(project.id)
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 0
    end

    test "joining as default client does not register daemon" do
      {_user, project, socket} = setup_socket()

      # Join as default client
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      # Verify daemon is not registered
      assert Sacrum.DaemonRegistry.daemon_connected?(project.id) == false
    end

    test "daemon joins project registers presence" do
      {_user, project, socket} = setup_socket()

      # No daemon initially
      assert Sacrum.DaemonRegistry.daemon_connected?(project.id) == false

      # Join as daemon
      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      # Daemon is registered
      assert Sacrum.DaemonRegistry.daemon_connected?(project.id) == true
      assert Sacrum.DaemonRegistry.daemon_count(project.id) == 1
    end
  end

  describe "broadcast helpers" do
    test "broadcast_task_created sends task_created event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_created(project.id, task)

      assert_broadcast "task_created", payload
      assert payload.id == task.id
      assert payload.title == task.title
    end

    test "broadcast_task_updated sends task_updated event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_updated(project.id, task)

      assert_broadcast "task_updated", payload
      assert payload.id == task.id
    end

    test "broadcast_task_deleted sends task_deleted event with position before-image" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task =
        project
        |> build_task()
        |> Map.put(:workflow_id, Ecto.UUID.generate())
        |> Map.put(:current_step_id, Ecto.UUID.generate())
        |> Map.put(:level, "ticket")
        |> Map.put(:archived, true)

      SacrumWeb.ProjectChannel.broadcast_task_deleted(project.id, task)

      assert_broadcast "task_deleted", payload
      assert_contract_payload_keys("task_deleted", payload)
      assert payload.schema_version == 1
      assert payload.id == task.id
      assert payload.current_step_id == task.current_step_id
      assert payload.workflow_id == task.workflow_id
      assert payload.level == "ticket"
      assert payload.archived == true
    end

    test "broadcast_step_transition_deleted sends relation before-image" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      transition = build_step_transition(project)

      SacrumWeb.ProjectChannel.broadcast_step_transition_deleted(project.id, transition)

      assert_broadcast "step_transition_deleted", payload
      assert_contract_payload_keys("step_transition_deleted", payload)
      assert payload.schema_version == 1
      assert payload.id == transition.id
      assert payload.from_step_id == transition.from_step_id
      assert payload.to_step_id == transition.to_step_id
      assert payload.project_id == project.id
    end

    test "broadcast_task_run_step_changed pushes payload with wire status to default client" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      payload = %{
        task_run_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        from_step_id: Ecto.UUID.generate(),
        to_step_id: Ecto.UUID.generate(),
        status: :executing,
        level: "ticket"
      }

      SacrumWeb.ProjectChannel.broadcast_task_run_step_changed(project.id, payload)

      assert_push "task_run_step_changed", pushed
      assert pushed.task_run_id == payload.task_run_id
      assert pushed.task_id == payload.task_id
      assert pushed.from_step_id == payload.from_step_id
      assert pushed.to_step_id == payload.to_step_id
      assert pushed.status == "executing"
      assert pushed.level == "ticket"
    end

    test "broadcast_task_run_step_changed encodes terminal status via wire_value" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      payload = %{
        task_run_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        from_step_id: Ecto.UUID.generate(),
        to_step_id: nil,
        status: :completed,
        level: "task"
      }

      SacrumWeb.ProjectChannel.broadcast_task_run_step_changed(project.id, payload)

      assert_push "task_run_step_changed", pushed
      assert pushed.to_step_id == nil
      assert pushed.status == "completed"
    end

    test "daemon client does NOT receive task_run_step_changed" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      payload = %{
        task_run_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        from_step_id: Ecto.UUID.generate(),
        to_step_id: Ecto.UUID.generate(),
        status: :executing,
        level: "ticket"
      }

      SacrumWeb.ProjectChannel.broadcast_task_run_step_changed(project.id, payload)

      refute_push "task_run_step_changed", _payload
    end

    test "broadcast_task_step_changed pushes payload to default client" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      payload = %{
        task_id: Ecto.UUID.generate(),
        from_step_id: Ecto.UUID.generate(),
        to_step_id: Ecto.UUID.generate(),
        workflow_id: Ecto.UUID.generate(),
        level: "ticket"
      }

      SacrumWeb.ProjectChannel.broadcast_task_step_changed(project.id, payload)

      assert_push "task_step_changed", pushed
      assert pushed.task_id == payload.task_id
      assert pushed.from_step_id == payload.from_step_id
      assert pushed.to_step_id == payload.to_step_id
      assert pushed.workflow_id == payload.workflow_id
      assert pushed.level == "ticket"
      refute Map.has_key?(pushed, :task_run_id)
      refute Map.has_key?(pushed, :status)
    end

    test "broadcast_task_step_changed allows nil from_step_id for initial assignment" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      payload = %{
        task_id: Ecto.UUID.generate(),
        from_step_id: nil,
        to_step_id: Ecto.UUID.generate(),
        workflow_id: Ecto.UUID.generate(),
        level: "epic"
      }

      SacrumWeb.ProjectChannel.broadcast_task_step_changed(project.id, payload)

      assert_push "task_step_changed", pushed
      assert pushed.from_step_id == nil
      assert pushed.level == "epic"
    end

    test "daemon client does NOT receive task_step_changed" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      payload = %{
        task_id: Ecto.UUID.generate(),
        from_step_id: Ecto.UUID.generate(),
        to_step_id: Ecto.UUID.generate(),
        workflow_id: Ecto.UUID.generate(),
        level: "ticket"
      }

      SacrumWeb.ProjectChannel.broadcast_task_step_changed(project.id, payload)

      refute_push "task_step_changed", _payload
    end

    test "task_payload includes complete task row fields needed by GUI stores" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      task =
        project
        |> build_task()
        |> Map.put(:archived, true)
        |> Map.put(:parent_id, Ecto.UUID.generate())
        |> Map.put(:status, "done")

      SacrumWeb.ProjectChannel.broadcast_task_updated(project.id, task)

      assert_push "task_updated", payload
      assert payload.archived == true
      assert payload.parent_id == task.parent_id
      assert payload.status == "done"
      assert payload.current_step_id == task.current_step_id
      assert payload.workflow_id == task.workflow_id
    end

    test "runtime payload keys match CDC contract for regular broadcast helpers" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      task = build_task(project)
      workflow = build_workflow(project)
      step = build_workflow_step(project)
      step_transition = build_step_transition(project)
      workflow_transition = build_workflow_transition(project)
      execution = build_step_execution(project)
      session_log = build_session_log(project)
      section = build_section(project)

      assert_broadcast_payload_keys("task_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_task_created(project.id, task)
      end)

      assert_broadcast_payload_keys("task_updated", fn ->
        SacrumWeb.ProjectChannel.broadcast_task_updated(project.id, task)
      end)

      assert_broadcast_payload_keys("task_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_task_deleted(project.id, task)
      end)

      assert_broadcast_payload_keys("workflow_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_workflow_created(project.id, workflow)
      end)

      assert_broadcast_payload_keys("workflow_updated", fn ->
        SacrumWeb.ProjectChannel.broadcast_workflow_updated(project.id, workflow)
      end)

      assert_broadcast_payload_keys("workflow_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_workflow_deleted(project.id, workflow)
      end)

      assert_broadcast_payload_keys("step_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_created(project.id, step)
      end)

      assert_broadcast_payload_keys("step_updated", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_updated(project.id, step)
      end)

      assert_broadcast_payload_keys("step_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_deleted(project.id, step)
      end)

      assert_broadcast_payload_keys("step_transition_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_transition_created(project.id, step_transition)
      end)

      assert_broadcast_payload_keys("step_transition_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_transition_deleted(project.id, step_transition)
      end)

      assert_broadcast_payload_keys("workflow_transition_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_workflow_transition_created(
          project.id,
          workflow_transition
        )
      end)

      assert_broadcast_payload_keys("workflow_transition_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_workflow_transition_deleted(
          project.id,
          workflow_transition
        )
      end)

      assert_broadcast_payload_keys("step_execution_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_execution_created(project.id, execution)
      end)

      assert_broadcast_payload_keys("step_execution_status_changed", fn ->
        SacrumWeb.ProjectChannel.broadcast_step_execution_status_changed(project.id, execution)
      end)

      assert_broadcast_payload_keys("task_run_step_changed", fn ->
        SacrumWeb.ProjectChannel.broadcast_task_run_step_changed(project.id, %{
          task_run_id: Ecto.UUID.generate(),
          task_id: task.id,
          from_step_id: Ecto.UUID.generate(),
          to_step_id: Ecto.UUID.generate(),
          status: :executing,
          level: "ticket"
        })
      end)

      assert_broadcast_payload_keys("task_step_changed", fn ->
        SacrumWeb.ProjectChannel.broadcast_task_step_changed(project.id, %{
          task_id: task.id,
          from_step_id: Ecto.UUID.generate(),
          to_step_id: Ecto.UUID.generate(),
          workflow_id: workflow.id,
          level: "ticket"
        })
      end)

      assert_broadcast_payload_keys("session_log_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_session_log_created(project.id, session_log)
      end)

      assert_broadcast_payload_keys("section_created", fn ->
        SacrumWeb.ProjectChannel.broadcast_section_created(project.id, section)
      end)

      assert_broadcast_payload_keys("section_updated", fn ->
        SacrumWeb.ProjectChannel.broadcast_section_updated(project.id, section)
      end)

      assert_broadcast_payload_keys("section_deleted", fn ->
        SacrumWeb.ProjectChannel.broadcast_section_deleted(project.id, section)
      end)
    end

    test "step payload includes editor and daemon configuration fields" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      output_schema = %{
        "type" => "object",
        "properties" => %{"approved" => %{"type" => "boolean"}},
        "required" => ["approved"]
      }

      step =
        project
        |> build_workflow_step()
        |> Map.put(:output_schema, output_schema)
        |> Map.put(:verbose_daemon_logging, true)

      SacrumWeb.ProjectChannel.broadcast_step_updated(project.id, step)

      assert_push "step_updated", payload
      assert payload.id == step.id
      assert payload.project_id == project.id
      assert payload.prompt == step.prompt
      assert payload.output_schema == output_schema
      assert payload.verbose_daemon_logging == true
    end

    test "step execution payload includes project, step, run, and handoff fields" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      execution =
        project
        |> build_step_execution()
        |> Map.put(:status, "waiting")
        |> Map.put(:handoff, %{"kind" => "human_input", "schema" => %{"type" => "object"}})

      SacrumWeb.ProjectChannel.broadcast_step_execution_status_changed(project.id, execution)

      assert_push "step_execution_status_changed", payload
      assert payload.id == execution.id
      assert payload.project_id == project.id
      assert payload.task_run_id == execution.task_run_id
      assert payload.step_id == execution.step_id
      assert payload.handoff == execution.handoff
      assert payload.status == "waiting"
    end
  end

  describe "client_type filtering - default client" do
    test "default client receives task_created event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      task = build_task(project)
      SacrumWeb.ProjectChannel.broadcast_task_created(project.id, task)

      assert_push "task_created", payload
      assert payload.id == task.id
    end

    test "default client does NOT receive run_step event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      data = %{
        execution: build_step_execution(project),
        step: build_workflow_step(project),
        task: build_task(project),
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      refute_push "run_step", _payload
    end

    test "default client does NOT receive cancel_step event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      data = %{step_execution_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate()}
      SacrumWeb.ProjectChannel.broadcast_cancel_step(project.id, data)

      refute_push "cancel_step", _payload
    end

    test "default client receives workflow_created event" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

      workflow = build_workflow(project)
      SacrumWeb.ProjectChannel.broadcast_workflow_created(project.id, workflow)

      assert_push "workflow_created", payload
      assert payload.id == workflow.id
    end
  end

  describe "client_type filtering - daemon client" do
    test "daemon client receives run_step event" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      execution = build_step_execution(project)
      task = build_task(project)

      data = %{
        execution: execution,
        step: build_workflow_step(project),
        task: task,
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      assert payload.id == execution.id
    end

    test "daemon client receives run_step payload with rendered prompt" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      step = build_workflow_step(project)
      task = build_task(project)
      execution = build_step_execution(project)

      data = %{
        execution: execution,
        step: step,
        task: task,
        rendered_prompt: "Do something with xabc123"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      assert payload.prompt == "Do something with xabc123"
      assert payload.agent_config == step.agent_config
      assert payload.worktree == task.worktree
    end

    test "run_step payload includes empty string for rendered prompt when empty" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      step = build_workflow_step(project)
      task = build_task(project)

      data = %{
        execution: build_step_execution(project),
        step: step,
        task: task,
        rendered_prompt: ""
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      assert payload.prompt == ""
    end

    test "run_step payload includes task worktree" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      task = build_task(project) |> Map.put(:worktree, "/path/to/worktree")

      data = %{
        execution: build_step_execution(project),
        step: build_workflow_step(project),
        task: task,
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      assert payload.worktree == "/path/to/worktree"
    end

    test "run_step payload only includes daemon-needed fields" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      execution = build_step_execution(project)
      step = build_workflow_step(project)
      task = build_task(project)

      data = %{
        execution: execution,
        step: step,
        task: task,
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      # Check for expected fields
      assert payload.id == execution.id
      assert payload.task_id == execution.task_id
      assert payload.prompt == "Test prompt"
      assert payload.agent_config == step.agent_config
      assert payload.worktree == task.worktree
      # Ensure orchestration fields are NOT included
      refute Map.has_key?(payload, :workflow_id)
      refute Map.has_key?(payload, :step_name)
      refute Map.has_key?(payload, :status)
      refute Map.has_key?(payload, :goal)
      refute Map.has_key?(payload, :auto_advance)
      refute Map.has_key?(payload, :is_final)
      refute Map.has_key?(payload, :transitions)
    end

    test "run_step payload includes output_schema when present" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      output_schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"]
      }

      execution = build_step_execution(project)
      step = build_workflow_step(project) |> Map.put(:output_schema, output_schema)
      task = build_task(project)

      data = %{
        execution: execution,
        step: step,
        task: task,
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      assert payload.output_schema == output_schema
    end

    test "run_step payload omits output_schema when nil" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      execution = build_step_execution(project)
      step = build_workflow_step(project)
      task = build_task(project)

      data = %{
        execution: execution,
        step: step,
        task: task,
        rendered_prompt: "Test prompt"
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_push "run_step", payload
      refute Map.has_key?(payload, :output_schema)
    end

    test "daemon client receives cancel_step event" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      data = %{step_execution_id: Ecto.UUID.generate(), task_id: Ecto.UUID.generate()}
      SacrumWeb.ProjectChannel.broadcast_cancel_step(project.id, data)

      assert_push "cancel_step", payload
      assert payload.step_execution_id == data.step_execution_id
    end

    test "daemon client does NOT receive task_created event" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      task = build_task(project)
      SacrumWeb.ProjectChannel.broadcast_task_created(project.id, task)

      refute_push "task_created", _payload
    end

    test "daemon client does NOT receive workflow_created event" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      workflow = build_workflow(project)
      SacrumWeb.ProjectChannel.broadcast_workflow_created(project.id, workflow)

      refute_push "workflow_created", _payload
    end

    test "daemon client does NOT receive section_created event" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      section = build_section(project)
      SacrumWeb.ProjectChannel.broadcast_section_created(project.id, section)

      refute_push "section_created", _payload
    end
  end

  describe "public chat event filtering" do
    test "token for another user cannot subscribe to public chat events" do
      {_user, project, _socket} = setup_socket()

      {:ok, other_user} =
        Users.insert(%{
          email: "other-token-chat@example.com",
          username: "other_token_chat",
          password: "password123"
        })

      {:ok, other_token, _api_token} =
        Auth.create_api_token(other_user, %{name: "other token"})

      {:ok, other_socket} = connect(UserSocket, %{"token" => other_token})

      assert {:error, %{reason: "not found"}} =
               subscribe_and_join(other_socket, "project:#{project.id}", %{})
    end
  end

  describe "run_step_payload broadcast" do
    test "includes verbose_daemon_logging when true" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      task = build_task(project)
      execution = build_step_execution(project)
      step = build_workflow_step(project) |> Map.put(:verbose_daemon_logging, true)

      data = %{
        execution: execution,
        rendered_prompt: "Test prompt",
        step: step,
        task: task
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_broadcast "run_step", payload
      assert payload.verbose_daemon_logging == true
      assert payload.id == execution.id
      assert payload.task_id == execution.task_id
    end

    test "omits verbose_daemon_logging when false" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      task = build_task(project)
      execution = build_step_execution(project)
      step = build_workflow_step(project) |> Map.put(:verbose_daemon_logging, false)

      data = %{
        execution: execution,
        rendered_prompt: "Test prompt",
        step: step,
        task: task
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_broadcast "run_step", payload
      # Should not include the field when false
      refute Map.has_key?(payload, :verbose_daemon_logging)
      assert payload.id == execution.id
      assert payload.task_id == execution.task_id
    end

    test "includes both output_schema and verbose_daemon_logging when both present" do
      {_user, project, socket} = setup_socket()

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

      task = build_task(project)
      execution = build_step_execution(project)

      step =
        build_workflow_step(project)
        |> Map.put(:verbose_daemon_logging, true)
        |> Map.put(:output_schema, %{
          "type" => "object",
          "properties" => %{"result" => %{"type" => "string"}}
        })

      data = %{
        execution: execution,
        rendered_prompt: "Test prompt",
        step: step,
        task: task
      }

      SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)

      assert_broadcast "run_step", payload
      assert payload.verbose_daemon_logging == true
      assert payload.output_schema == step.output_schema
    end
  end

  defp build_task(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      short_id: "xabc123",
      title: "Test Task",
      description: "A task",
      level: "task",
      priority: "medium",
      tags: ["test"],
      needs_human_review: false,
      review_comment: nil,
      rejection_reason: nil,
      revision_feedback: nil,
      started_at: now,
      completed_at: nil,
      project_id: project.id,
      workflow_id: nil,
      current_step_id: nil,
      parent_id: nil,
      status: "ready",
      archived: false,
      worktree: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_workflow(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      name: "Test Workflow",
      description: "A workflow",
      is_default: false,
      is_final: false,
      display_order: 1,
      metadata: %{},
      initial_step_id: nil,
      kanban_column: nil,
      project_id: project.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_step_transition(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      from_step_id: Ecto.UUID.generate(),
      to_step_id: Ecto.UUID.generate(),
      label: "next",
      project_id: project.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_workflow_transition(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      from_workflow_id: Ecto.UUID.generate(),
      to_workflow_id: Ecto.UUID.generate(),
      target_step_id: Ecto.UUID.generate(),
      label: "promote",
      project_id: project.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_step_execution(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      task_run_id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      step_id: Ecto.UUID.generate(),
      project_id: project.id,
      step_name: "Test Step",
      step_type: "execute",
      status: "pending",
      context: nil,
      prompt: nil,
      output: nil,
      transition_result: nil,
      model: nil,
      model_provider: nil,
      input_tokens: nil,
      output_tokens: nil,
      cost: nil,
      duration_ms: nil,
      handoff: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_session_log(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      step_execution_id: Ecto.UUID.generate(),
      project_id: project.id,
      content: "session log",
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_workflow_step(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      name: "Test Step",
      goal: "Test goal",
      agents: ["test_agent"],
      skills: ["skill1"],
      agent_config: %{},
      is_final: false,
      step_order: 1,
      step_type: "execute",
      workflow_id: Ecto.UUID.generate(),
      project_id: project.id,
      prompt: "Execute the test step",
      output_schema: nil,
      verbose_daemon_logging: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_section(project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      project_id: project.id,
      section_type: "context",
      content: "Test content",
      section_order: 1,
      done: false,
      done_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp assert_broadcast_payload_keys(event, broadcast_fun) do
    broadcast_fun.()
    assert_broadcast ^event, payload
    assert_contract_payload_keys(event, payload)
  end

  defp assert_contract_payload_keys(event, payload) do
    assert {:ok, contract} = ProjectChannelCdcContract.contract_for(event)
    assert Enum.sort(Map.keys(payload)) == Enum.sort(contract.payload_keys)
  end
end
