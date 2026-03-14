defmodule SacrumWeb.ProjectChannelTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest

  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
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

    test "broadcast_task_deleted sends task_deleted event with id only" do
      {_user, project, socket} = setup_socket()
      {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

      task = build_task(project)

      SacrumWeb.ProjectChannel.broadcast_task_deleted(project.id, task)

      assert_broadcast "task_deleted", %{id: id}
      assert id == task.id
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
      refute Map.has_key?(payload, :eval_prompt)
      refute Map.has_key?(payload, :is_final)
      refute Map.has_key?(payload, :transitions)
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
      auto_advance: false,
      is_default: false,
      display_order: 1,
      metadata: %{},
      initial_step_id: nil,
      project_id: project.id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_step_execution(_project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      workflow_id: Ecto.UUID.generate(),
      step_name: "Test Step",
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
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_workflow_step(_project) do
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
      workflow_id: Ecto.UUID.generate(),
      prompt: "Execute the test step",
      eval_prompt: "Evaluate the test step result",
      inserted_at: now,
      updated_at: now
    }
  end

  defp build_section(_project) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      section_type: "context",
      content: "Test content",
      section_order: 1,
      done: false,
      done_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end
end
