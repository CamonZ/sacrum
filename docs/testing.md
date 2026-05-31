# Testing Guide

Sacrum uses ExUnit with Ecto SQL Sandbox for isolated, concurrent database tests. All tests live under `test/` mirroring the `lib/` structure.

## Test Infrastructure

### Case Templates

| Module | Purpose | Key Imports |
|--------|---------|-------------|
| `Sacrum.DataCase` | Database/repo tests | `Ecto`, `Ecto.Changeset`, `Ecto.Query`, `errors_on/1` |
| `SacrumWeb.ConnCase` | HTTP/GraphQL tests | `Phoenix.ConnTest`, `Plug.Conn`, `create_user/1`, `authenticate/2` |

Both templates set up the Ecto SQL Sandbox automatically. Use `async: true` for parallel execution.

### External CLI Boundaries

Ordinary tests should exercise Sacrum modules and contracts directly, not a
globally installed CLI binary. Do not shell out to `vtb` from unit, contract, or
feature tests to prove behavior that lives in this repository.

If CLI parity matters, assert against shared in-repo code or a documented
contract instead of parsing `vtb --help` output or depending on whatever `vtb`
happens to be on `PATH`. Tests that intentionally validate an installed CLI
belong in an explicitly tagged integration suite.

### Helper Functions

**`SacrumWeb.ConnCase` provides:**

```elixir
# Create a test user with defaults
create_user()
create_user(%{email: "other@example.com", username: "other", password: "password123"})

# Add bearer token auth to a connection
authenticate(conn, user)
```

**`Sacrum.DataCase` provides:**

```elixir
# Convert changeset errors to a readable map
errors_on(changeset)
# => %{title: ["can't be blank"]}
```

### Common Setup Pattern

Most test modules define private setup helpers and use named setups:

```elixir
defmodule MyTest do
  use Sacrum.DataCase, async: true

  defp create_user(attrs \\ %{email: "test@example.com", username: "testuser", password: "password123"}) do
    {:ok, user} = Sacrum.Repo.Users.insert(attrs)
    user
  end

  defp create_project(user) do
    {:ok, project} = Sacrum.Repo.Projects.insert(user, %{name: "Test Project"})
    project
  end

  # Named setup for reuse across describe blocks
  defp setup_user_and_project(_context) do
    user = create_user()
    project = create_project(user)
    %{user: user, project: project}
  end

  describe "my feature" do
    setup [:setup_user_and_project]

    test "works", %{user: user, project: project} do
      # ...
    end
  end
end
```

## GraphQL Tests

GraphQL tests use `SacrumWeb.ConnCase` and POST queries to `/graphql`.

### Query Helper

Define a private helper in your test module:

```elixir
defp graphql(conn, query) do
  post(conn, "/graphql", %{"query" => query})
end
```

### Testing Queries

```elixir
describe "project queries" do
  setup [:setup_user_and_project]

  test "lists projects", %{conn: conn, user: user, project: project} do
    result =
      conn
      |> authenticate(user)
      |> graphql("{ projects { id name slug } }")
      |> json_response(200)

    assert [found] = result["data"]["projects"]
    assert found["id"] == project.id
  end

  test "gets a single project by id", %{conn: conn, user: user, project: project} do
    result =
      conn
      |> authenticate(user)
      |> graphql(~s|{ project(id: "#{project.id}") { id name } }|)
      |> json_response(200)

    assert result["data"]["project"]["id"] == project.id
  end
end
```

### Testing Mutations

```elixir
test "creates a task", %{conn: conn, user: user, project: project} do
  result =
    conn
    |> authenticate(user)
    |> graphql("""
      mutation {
        createTask(
          projectId: "#{project.id}"
          title: "New Task"
          description: "Task desc"
          level: "high"
          priority: "critical"
          tags: ["bug", "critical"]
        ) { id title description level priority tags }
      }
    """)
    |> json_response(200)

  data = result["data"]["createTask"]
  assert data["title"] == "New Task"
  assert data["tags"] == ["bug", "critical"]
end
```

### Testing GraphQL Errors

```elixir
test "returns error for nonexistent project", %{conn: conn, user: user} do
  fake_id = Ecto.UUID.generate()

  result =
    conn
    |> authenticate(user)
    |> graphql(~s|{ project(id: "#{fake_id}") { id } }|)
    |> json_response(200)

  assert result["data"]["project"] == nil
  assert [%{"message" => _}] = result["errors"]
end
```

### Testing Authentication

```elixir
test "rejects unauthenticated requests with 401", %{conn: conn} do
  conn = graphql(conn, "{ projects { id } }")
  assert conn.status == 401
end

test "rejects invalid token with 401", %{conn: conn} do
  conn =
    conn
    |> put_req_header("authorization", "Bearer sac_invalidtoken")
    |> graphql("{ projects { id } }")

  assert conn.status == 401
end
```

### Custom Scalar Gotchas

- **`:json` scalar** — Only accepts `String` input. In inline queries, use escaped JSON: `~S|{"key":"val"}|` inside `~s` strings. Variable-based queries with raw maps don't work because Absinthe parses them as input objects.
- **Type names in variable declarations** — Use Absinthe names: `Uuid4` (not `UUID4`), `Json` (not `JSON`), `Decimal` (not `DECIMAL`). Check with `Absinthe.Schema.lookup_type(Schema, :identifier).name`.
- **Decimal scalar** — Accepts string input like `"0.05"`.

## Repository Tests

Use `Sacrum.DataCase` for testing repo modules directly.

### Testing CRUD Operations

```elixir
describe "insert/2" do
  test "creates task with valid attrs" do
    user = create_user()
    project = create_project(user)

    {:ok, task} = Sacrum.Repo.Tasks.insert(project, %{title: "My Task", description: "A description"})

    assert task.title == "My Task"
    assert task.project_id == project.id
    refute Map.has_key?(task, :short_id)
  end

  test "rejects missing title" do
    user = create_user()
    project = create_project(user)

    {:error, changeset} = Sacrum.Repo.Tasks.insert(project, %{})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end
end
```

### Testing Domain Validation Errors

```elixir
describe "add_dependency/2" do
  test "rejects self-dependency" do
    task = create_task(project, "A")
    assert {:error, :self_dependency} = TaskDependencies.add_dependency(task, task)
  end

  test "rejects circular dependency" do
    task_a = create_task(project, "A")
    task_b = create_task(project, "B")

    {:ok, _} = TaskDependencies.add_dependency(task_a, task_b)
    assert {:error, :circular_dependency} = TaskDependencies.add_dependency(task_b, task_a)
  end

  test "rejects cross-project dependency" do
    task_1 = create_task(project_1, "Task 1")
    task_2 = create_task(project_2, "Task 2")

    assert {:error, :different_projects} = TaskDependencies.add_dependency(task_1, task_2)
  end
end
```

## Channel Tests

Channel tests use `Sacrum.DataCase` with `Phoenix.ChannelTest` imported.

### Setup

```elixir
defmodule SacrumWeb.ProjectChannelTest do
  use Sacrum.DataCase, async: true
  import Phoenix.ChannelTest

  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint

  defp setup_socket do
    {:ok, user} = Users.insert(%{email: "channel@example.com", username: "channeluser", password: "password123"})
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {user, project, socket}
  end
end
```

### Testing Channel Joins

```elixir
test "can join project channel for owned project" do
  {_user, project, socket} = setup_socket()
  assert {:ok, _reply, socket} = subscribe_and_join(socket, "project:#{project.id}")
  assert socket.assigns.project.id == project.id
end

test "cannot join another user's project" do
  {_user, _project, socket} = setup_socket()
  {:ok, other_user} = Users.insert(%{email: "other@example.com", username: "other", password: "password123"})
  {:ok, other_project} = Projects.insert(other_user, %{name: "Other Project"})

  assert {:error, %{reason: "not found"}} = subscribe_and_join(socket, "project:#{other_project.id}")
end
```

### Testing Client Type Filtering

```elixir
test "daemon client receives run_step event" do
  {_user, project, socket} = setup_socket()
  {:ok, _reply, _socket} =
    subscribe_and_join(socket, "project:#{project.id}", %{"client_type" => "daemon"})

  SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)
  assert_push "run_step", payload
end

test "default client does NOT receive run_step event" do
  {_user, project, socket} = setup_socket()
  {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}", %{})

  SacrumWeb.ProjectChannel.broadcast_run_step(project.id, data)
  refute_push "run_step", _payload
end
```

### Testing Broadcasts from Repo Operations

```elixir
test "creating a task broadcasts task_created" do
  {_user, project} = setup_channel()

  {:ok, task} = Tasks.insert(project, %{title: "New Task"})

  assert_broadcast "task_created", payload
  assert payload.id == task.id
  assert payload.title == "New Task"
end

test "deleting a task broadcasts task_deleted" do
  {_user, project} = setup_channel()
  {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
  assert_broadcast "task_created", _

  {:ok, _} = Tasks.delete(task)
  assert_broadcast "task_deleted", payload
  assert payload.id == task.id
  assert payload.schema_version == 1
  assert payload.current_step_id == task.current_step_id
end
```

### Build Helpers for Channel Test Data

Channel tests often need plain maps (not DB records) for broadcast payloads:

```elixir
defp build_task(project) do
  now = DateTime.utc_now()
  %{
    id: Ecto.UUID.generate(),
    title: "Test Task",
    project_id: project.id,
    inserted_at: now,
    updated_at: now
  }
end
```

## Socket Tests

```elixir
defmodule SacrumWeb.UserSocketTest do
  use Sacrum.DataCase, async: true

  test "connects successfully with valid API token" do
    {user, token} = create_user_and_token()
    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    assert socket.assigns.current_user.id == user.id
  end

  test "rejects connection with invalid token" do
    assert :error = UserSocket.connect(%{"token" => "sac_invalid"}, %Phoenix.Socket{}, %{})
  end
end
```

## Running Tests

```bash
mix test                           # Run all tests
mix test test/path/to_test.exs     # Run specific file
mix test test/path:42              # Run specific test by line number
mix test --failed                  # Re-run previously failed tests
mix precommit                      # Full check: compile, deps, format, test
```
