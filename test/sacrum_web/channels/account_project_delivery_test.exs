defmodule SacrumWeb.AccountProjectDeliveryTest do
  use Sacrum.DataCase, async: false
  import Phoenix.ChannelTest

  alias Sacrum.ChannelCollector
  alias Sacrum.Realtime.Cdc.Projector
  alias Sacrum.Realtime.ProjectChannelCdcContract, as: Contract
  alias Sacrum.Repo.{Projects, Tasks, Users}
  alias Sacrum.Repo.Schemas
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint
  @rows [
    {"tasks", Schemas.Task, [:insert, :update, :delete],
     ["task_created", "task_updated", "task_deleted", "task_parent_changed", "task_step_changed"]},
    {"task_dependencies", Schemas.TaskDependency, [:insert, :delete],
     ["task_dependency_created", "task_dependency_deleted"]},
    {"workflows", Schemas.Workflow, [:insert, :update, :delete],
     ["workflow_created", "workflow_updated", "workflow_deleted"]},
    {"workflow_steps", Schemas.WorkflowStep, [:insert, :update, :delete],
     ["step_created", "step_updated", "step_deleted"]},
    {"step_transitions", Schemas.StepTransition, [:insert, :delete],
     ["step_transition_created", "step_transition_deleted"]},
    {"workflow_transitions", Schemas.WorkflowTransition, [:insert, :delete],
     ["workflow_transition_created", "workflow_transition_deleted"]},
    {"step_executions", Schemas.StepExecution, [:insert, :update],
     ["step_execution_created", "step_execution_status_changed"]},
    {"task_runs", Schemas.TaskRun, [:insert, :update],
     ["task_run_created", "task_run_updated", "task_run_step_changed"]},
    {"session_logs", Schemas.SessionLog, [:insert, :update],
     ["session_log_created", "session_log_updated"]},
    {"task_sections", Schemas.TaskSection, [:insert, :update, :delete],
     ["section_created", "section_updated", "section_deleted"]},
    {"code_refs", Schemas.CodeRef, [:insert, :update, :delete],
     ["code_ref_created", "code_ref_updated", "code_ref_deleted"]},
    {"artifacts", Schemas.Artifact, [:insert, :update, :delete],
     ["artifact_created", "artifact_updated", "artifact_deleted"]},
    {"artifact_links", Schemas.ArtifactLink, [:insert, :update, :delete],
     ["artifact_link_created", "artifact_link_updated", "artifact_link_deleted"]},
    {"notifications", Schemas.Notification, [:insert, :update, :delete],
     ["notification_created", "notification_updated", "notification_deleted"]}
  ]

  test "all 39 CDC event types have exact channel parity and preserve legacy filtering" do
    {user, project, task} = fixture()
    account = client(user, "accounts:me", %{"user_id" => Ecto.UUID.generate()})
    sibling = client(user, "accounts:me")
    project_client = client(user, "project:#{project.id}")
    daemon = client(user, "project:#{project.id}", %{"client_type" => "daemon"})
    {foreign_user, _, _} = fixture()
    foreign = client(foreign_user, "accounts:me")
    clients = [account, sibling, project_client, daemon, foreign]

    seen =
      for {table, schema, operations, expected} <- @rows, reduce: MapSet.new() do
        seen ->
          events = for op <- operations, do: row_event(table, schema, op, user, project, task)
          assert {:ok, results} = Projector.project_events(events)
          assert MapSet.new(Enum.map(results, & &1.event)) == MapSet.new(expected)
          flush_channels(clients)
          project_messages = ChannelCollector.take(project_client.collector)
          account_messages = ChannelCollector.take(account.collector)
          sibling_messages = ChannelCollector.take(sibling.collector)
          assert length(project_messages) == length(results)
          assert Enum.map(project_messages, & &1.event) == Enum.map(results, & &1.event)
          assert parity(project_messages, project.id) == wire(account_messages)
          assert wire(account_messages) == wire(sibling_messages)
          assert ChannelCollector.take(daemon.collector) == []
          assert ChannelCollector.take(foreign.collector) == []

          for message <- project_messages do
            {:ok, contract} = Contract.contract_for(message.event)
            # Preserve the existing code-ref serializer, which predates the
            # contract's order_index declaration; this ticket is additive only.
            keys =
              if String.starts_with?(message.event, "code_ref_"),
                do: contract.payload_keys -- [:order_index],
                else: contract.payload_keys

            assert Enum.sort(Map.keys(message.payload)) == Enum.sort(keys)
            refute Map.has_key?(message.payload, :user_id)
          end

          MapSet.union(seen, MapSet.new(expected))
      end

    assert MapSet.size(seen) == 39
    assert seen == MapSet.new(Contract.regular_event_names())
  end

  test "generated ownership fixtures deliver once to every owner subscriber and no foreign client" do
    owners = for _ <- 1..4, do: fixture()

    subscribers =
      for {user, _, _} <- owners, _ <- 1..2, do: {user.id, client(user, "accounts:me")}

    for {user, project, _task} <- owners, emission <- 1..3 do
      record = row_event("notifications", Schemas.Notification, :insert, user, project, nil)
      record = put_in(record.new_record.message, "**通知 #{emission}** 🌍")
      assert {:ok, [_]} = Projector.project_events(record)
      flush_channels(Enum.map(subscribers, &elem(&1, 1)))

      for {owner_id, subscriber} <- subscribers do
        messages = ChannelCollector.take(subscriber.collector)

        if owner_id == user.id do
          assert [%{event: "notification_created", payload: payload}] = messages
          assert payload.id == record.new_record.id
          assert payload.project_id == project.id
          assert payload.message == record.new_record.message
        else
          assert messages == []
        end
      end
    end
  end

  test "subscription sequence model covers leaves, reconnects and independent project subscriptions" do
    {user, project, _} = fixture()
    {other_user, other_project, _} = fixture()
    fixtures = %{a: {user, project}, b: {other_user, other_project}}
    collectors = Map.new([:a1, :a2, :b1], &{&1, collector()})
    owners = %{a1: :a, a2: :a, b1: :b}

    actions = [
      {:join, :a1, :account},
      {:emit, :a},
      {:join, :a2, :project},
      {:emit, :a},
      {:join, :b1, :account},
      {:emit, :b},
      {:join, :a1, :project},
      {:emit, :a},
      {:leave, :a1, :account},
      {:emit, :a},
      {:join, :a2, :account},
      {:emit, :a},
      {:leave, :a1, :project},
      {:emit, :a},
      {:join, :a1, :account},
      {:emit, :a},
      {:leave, :a2, :project},
      {:emit, :b},
      {:emit, :a}
    ]

    Enum.reduce(actions, %{}, fn
      {:join, who, scope}, subscriptions ->
        {owner, owned_project} = Map.fetch!(fixtures, Map.fetch!(owners, who))
        topic = if scope == :account, do: "accounts:me", else: "project:#{owned_project.id}"
        joined = client(owner, topic, %{}, Map.fetch!(collectors, who))
        Map.put(subscriptions, {who, scope}, joined)

      {:leave, who, scope}, subscriptions ->
        {joined, remaining} = Map.pop!(subscriptions, {who, scope})
        Process.unlink(joined.socket.channel_pid)
        close(joined.socket)
        remaining

      {:emit, owner}, subscriptions ->
        {owned_user, owned_project} = Map.fetch!(fixtures, owner)

        event =
          row_event(
            "notifications",
            Schemas.Notification,
            :insert,
            owned_user,
            owned_project,
            nil
          )

        assert {:ok, [_]} = Projector.project_events(event)
        flush_channels(Map.values(subscriptions))

        for {who, inbox} <- collectors do
          expected_topics =
            for {{subscriber, scope}, _} <- subscriptions,
                subscriber == who and Map.fetch!(owners, who) == owner,
                do: if(scope == :account, do: "accounts:me", else: "project:#{owned_project.id}")

          messages = ChannelCollector.take(inbox)
          assert Enum.sort(Enum.map(messages, & &1.topic)) == Enum.sort(expected_topics)

          assert Enum.all?(
                   messages,
                   &(&1.event == "notification_created" and &1.payload.id == event.new_record.id)
                 )
        end

        subscriptions
    end)
  end

  defp fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "parallel-#{n}@example.com",
        username: "parallel_#{n}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Parallel #{n}"})
    {:ok, task} = Tasks.insert(project, %{title: "Parallel task"})
    {user, project, task}
  end

  defp collector,
    do: start_supervised!(%{id: make_ref(), start: {ChannelCollector, :start_link, [[]]}})

  defp client(user, topic, params \\ %{}, inbox \\ nil) do
    inbox = inbox || collector()
    socket = socket(UserSocket, "parallel:#{user.id}", %{current_user: user})
    socket = %{socket | transport_pid: inbox}
    {:ok, _, joined} = Phoenix.ChannelTest.join(socket, topic, params)
    %{socket: joined, collector: inbox}
  end

  defp flush_channels(clients), do: Enum.each(clients, &:sys.get_state(&1.socket.channel_pid))
  defp wire(messages), do: Enum.map(messages, &{&1.event, &1.payload})

  defp parity(messages, project_id),
    do: Enum.map(messages, &{&1.event, Map.put(&1.payload, :project_id, project_id)})

  defp row_event(table, schema, operation, user, project, task) do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      project_id: project.id,
      task_id: task && task.id,
      inserted_at: now,
      updated_at: now,
      title: "**Markdown** 日本語 🌍",
      content: "# Heading\n\nUnicode 🌍",
      message: "**通知** 🌍",
      body: "# Artifact\n\n```json\n{\"nested\":[null,\"🌍\"]}\n```",
      filename: "report.md",
      metadata: nil,
      context: %{"nested" => [%{"nullable" => nil, "unicode" => "🌍"}]},
      status: if(table == "task_runs", do: :completed, else: "ready"),
      parent_id: Ecto.UUID.generate(),
      current_step_id: Ecto.UUID.generate(),
      level: "task",
      severity: "info"
    }

    record = struct(schema, Map.take(attrs, schema.__schema__(:fields))) |> Map.from_struct()
    changes = %{status: %{old_value: "pending", new_value: record[:status]}}

    changes =
      if table == "tasks",
        do:
          Map.merge(changes, %{parent_id: %{old_value: nil}, current_step_id: %{old_value: nil}}),
        else: changes

    %WalEx.Event{
      source: %WalEx.Event.Source{table: table},
      type: operation,
      new_record: if(operation != :delete, do: record),
      old_record: if(operation == :delete, do: record),
      changes: changes
    }
  end
end
