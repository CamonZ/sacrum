defmodule SacrumWeb.Graphql.TaskIdentifiersTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  defp graphql(conn, query) do
    conn
    |> post("/graphql", %{"query" => query})
    |> json_response(200)
  end

  setup %{conn: conn} do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Vertebrae", key_prefix: "VTB"})
    %{conn: authenticate(conn, user), user: user, project: project}
  end

  test "projects expose and accept a key prefix", %{conn: conn} do
    created =
      graphql(conn, """
        mutation {
          createProject(name: "Sacrum", keyPrefix: "sac", codexInstalled: true, claudeInstalled: false) {
            id keyPrefix
          }
        }
      """)

    assert %{"id" => id, "keyPrefix" => "SAC"} = created["data"]["createProject"]

    updated =
      graphql(conn, ~s|mutation { updateProject(id: "#{id}", keyPrefix: "SCR") { keyPrefix } }|)

    assert updated["data"]["updateProject"]["keyPrefix"] == "SCR"
  end

  test "prefix changes are rejected once tasks are numbered", %{conn: conn, project: project} do
    graphql(conn, ~s|mutation { createTask(projectId: "#{project.id}", title: "One") { id } }|)

    result =
      graphql(conn, ~s|mutation { updateProject(id: "#{project.id}", keyPrefix: "VRT") { id } }|)

    assert result["data"]["updateProject"] == nil
    assert [%{"message" => message}] = result["errors"]
    assert message =~ "cannot be changed after task identifiers have been issued"
  end

  test "creation, listing and lookup expose the readable key", %{conn: conn, project: project} do
    created =
      graphql(conn, """
        mutation {
          createTask(projectId: "#{project.id}", title: "Epic", level: "epic") { id number key }
        }
      """)

    assert %{"id" => epic_id, "number" => 1, "key" => "VTB-1"} = created["data"]["createTask"]

    graphql(conn, """
      mutation { createTask(projectId: "#{project.id}", title: "Ticket", level: "ticket") { id } }
    """)

    listed = graphql(conn, ~s|{ tasks(projectId: "#{project.id}") { id key } }|)
    assert Enum.map(listed["data"]["tasks"], & &1["key"]) == ["VTB-1", "VTB-2"]

    by_uuid = graphql(conn, ~s|{ task(id: "#{epic_id}") { key } }|)
    assert by_uuid["data"]["task"]["key"] == "VTB-1"

    prefix = String.slice(epic_id, 0, 8)

    by_prefix =
      graphql(
        conn,
        ~s|{ resolveShortId(projectId: "#{project.id}", prefix: "#{prefix}") { key } }|
      )

    assert by_prefix["data"]["resolveShortId"]["key"] == "VTB-1"

    by_key = graphql(conn, ~s|{ taskByKey(projectId: "#{project.id}", key: "vtb-2") { title } }|)
    assert by_key["data"]["taskByKey"]["title"] == "Ticket"
  end

  test "edits keep the key", %{conn: conn, project: project} do
    created =
      graphql(conn, ~s|mutation { createTask(projectId: "#{project.id}", title: "T") { id } }|)

    id = created["data"]["createTask"]["id"]

    updated =
      graphql(conn, """
        mutation { updateTask(id: "#{id}", title: "Renamed", level: "epic") { key } }
      """)

    assert updated["data"]["updateTask"]["key"] == "VTB-1"
  end

  test "taskByKey reports malformed and unknown keys", %{conn: conn, project: project} do
    malformed = graphql(conn, ~s|{ taskByKey(projectId: "#{project.id}", key: "VTB") { id } }|)
    assert [%{"message" => "invalid task key 'VTB'" <> _rest}] = malformed["errors"]

    unknown = graphql(conn, ~s|{ taskByKey(projectId: "#{project.id}", key: "VTB-9") { id } }|)
    assert [%{"message" => "task with key 'VTB-9' not found"}] = unknown["errors"]
  end

  test "taskByKey does not resolve another user's tasks", %{project: project, user: user} do
    {:ok, _task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Secret"})
    other_user = create_user(%{email: "other@example.com", username: "other"})

    result =
      build_conn()
      |> authenticate(other_user)
      |> graphql(~s|{ taskByKey(projectId: "#{project.id}", key: "VTB-1") { id } }|)

    assert result["data"]["taskByKey"] == nil
    assert [%{"message" => "task with key 'VTB-1' not found"}] = result["errors"]
  end
end
