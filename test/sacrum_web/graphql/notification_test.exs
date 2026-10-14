defmodule SacrumWeb.Graphql.NotificationTest do
  use SacrumWeb.ConnCase, async: true

  import Sacrum.CdcAssertions

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Notification

  @publish """
  mutation Publish($projectId: Uuid4!, $message: String!, $severity: String!) {
    publishNotification(projectId: $projectId, message: $message, severity: $severity) {
      id projectId message severity insertedAt readAt
    }
  }
  """

  @history """
  query History(
    $projectId: Uuid4!
    $afterInsertedAt: Datetime
    $afterId: Uuid4
    $limit: Int
    $unreadOnly: Boolean
  ) {
    projectNotifications(
      projectId: $projectId
      afterInsertedAt: $afterInsertedAt
      afterId: $afterId
      limit: $limit
      unreadOnly: $unreadOnly
    ) {
      hasMore
      notifications { id projectId message severity insertedAt readAt }
    }
  }
  """

  @mark_read """
  mutation MarkRead($ids: [Uuid4!]!) {
    markNotificationsRead(ids: $ids) { id readAt }
  }
  """

  @markdown "Task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11) has completed. " <>
              "Artifact [report](vtb://artifact/9b7c1a52-1f0e-4f43-a0c7-2b8d7e6b1c10) " <>
              "has been added to ticket [Notify](vtb://ticket/27018ff0-d663-4fb4-93ad-0a65777cbd71)."

  setup %{conn: conn} do
    user = create_named_user("notify-graphql")
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Notifications API"})
    %{conn: conn, user: user, project: project}
  end

  defp create_named_user(prefix) do
    suffix = System.unique_integer([:positive])

    create_user(%{
      email: "#{prefix}-#{suffix}@example.com",
      username: "#{String.replace(prefix, "-", "_")}_#{suffix}"
    })
  end

  defp run(conn, user, query, variables) do
    conn
    |> authenticate(user)
    |> post("/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  defp publish(ctx, variables) do
    run(
      ctx.conn,
      Map.get(variables, :user, ctx.user),
      @publish,
      Map.merge(
        %{"projectId" => ctx.project.id, "message" => @markdown, "severity" => "success"},
        Map.drop(variables, [:user])
      )
    )
  end

  defp notification_count, do: Repo.aggregate(Notification, :count)

  describe "publishNotification" do
    test "stores the notification for the caller's project and preserves Markdown", ctx do
      result = publish(ctx, %{})

      assert %{
               "id" => id,
               "projectId" => project_id,
               "message" => @markdown,
               "severity" => "success",
               "insertedAt" => inserted_at,
               "readAt" => nil
             } = result["data"]["publishNotification"]

      assert project_id == ctx.project.id
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(inserted_at)
      assert Repo.get!(Notification, id).message == @markdown
    end

    test "rejects unauthenticated requests", ctx do
      conn = post(ctx.conn, "/graphql", %{"query" => @publish, "variables" => %{}})

      assert conn.status == 401
      assert notification_count() == 0
    end

    test "rejects another user's project through the project scope foreign key", ctx do
      other = create_named_user("notify-graphql-other")
      result = publish(ctx, %{user: other})

      assert result["data"]["publishNotification"] == nil
      assert [%{"message" => "project_id: does not exist"}] = result["errors"]
      assert notification_count() == 0
    end

    test "rejects invalid severity and oversized messages", ctx do
      oversized = String.duplicate("a", Notification.max_message_bytes() + 1)

      for {variables, field} <- [
            {%{"severity" => "critical"}, "severity"},
            {%{"message" => oversized}, "message"},
            {%{"message" => ""}, "message"}
          ] do
        result = publish(ctx, variables)

        assert result["data"]["publishNotification"] == nil
        assert [%{"message" => message}] = result["errors"]
        assert message =~ field
      end

      assert notification_count() == 0
    end

    test "rejects malformed project ids before resolving", ctx do
      result = publish(ctx, %{"projectId" => "not-a-uuid"})

      assert [_ | _] = result["errors"]
      assert notification_count() == 0
    end

    test "failed publications are not broadcast", ctx do
      :ok = subscribe_project(ctx.project.id)
      _result = publish(ctx, %{"severity" => "critical"})

      refute_project_broadcast("notification_created")
    end
  end

  describe "projectNotifications" do
    test "pages history with an insertedAt/id cursor", ctx do
      ids =
        for message <- ["one", "two", "three"] do
          publish(ctx, %{"message" => message})["data"]["publishNotification"]["id"]
        end

      first = run(ctx.conn, ctx.user, @history, %{"projectId" => ctx.project.id, "limit" => 2})

      assert %{"hasMore" => true, "notifications" => [_one, last] = first_page} =
               first["data"]["projectNotifications"]

      second =
        run(ctx.conn, ctx.user, @history, %{
          "projectId" => ctx.project.id,
          "afterInsertedAt" => last["insertedAt"],
          "afterId" => last["id"],
          "limit" => 2
        })

      assert %{"hasMore" => false, "notifications" => second_page} =
               second["data"]["projectNotifications"]

      assert Enum.map(first_page ++ second_page, & &1["id"]) == ids
      assert Enum.map(first_page ++ second_page, & &1["message"]) == ["one", "two", "three"]
    end

    test "requires both cursor parts", ctx do
      result =
        run(ctx.conn, ctx.user, @history, %{
          "projectId" => ctx.project.id,
          "afterId" => Ecto.UUID.generate()
        })

      assert result["data"]["projectNotifications"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "provided together"
    end

    test "rejects out-of-range limits", ctx do
      result = run(ctx.conn, ctx.user, @history, %{"projectId" => ctx.project.id, "limit" => 0})

      assert [%{"message" => message}] = result["errors"]
      assert message =~ "limit"
    end

    test "marks notifications read and filters them with unreadOnly", ctx do
      [read_id, unread_id] =
        for message <- ["read me", "leave me"] do
          publish(ctx, %{"message" => message})["data"]["publishNotification"]["id"]
        end

      marked = run(ctx.conn, ctx.user, @mark_read, %{"ids" => [read_id]})

      assert [%{"id" => ^read_id, "readAt" => read_at}] =
               marked["data"]["markNotificationsRead"]

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(read_at)

      unread =
        run(ctx.conn, ctx.user, @history, %{"projectId" => ctx.project.id, "unreadOnly" => true})

      assert [%{"id" => ^unread_id, "readAt" => nil}] =
               unread["data"]["projectNotifications"]["notifications"]
    end

    test "markNotificationsRead ignores other users' notifications and rejects empty ids", ctx do
      id = publish(ctx, %{})["data"]["publishNotification"]["id"]
      other = create_named_user("notify-graphql-other")

      assert %{"data" => %{"markNotificationsRead" => []}} =
               run(ctx.conn, other, @mark_read, %{"ids" => [id]})

      assert Repo.get!(Notification, id).read_at == nil

      empty = run(ctx.conn, ctx.user, @mark_read, %{"ids" => []})
      assert [%{"message" => message}] = empty["errors"]
      assert message =~ "ids must contain"
    end

    test "does not expose another user's project", ctx do
      _published = publish(ctx, %{})
      other = create_named_user("notify-graphql-other")

      result = run(ctx.conn, other, @history, %{"projectId" => ctx.project.id})

      assert result["data"]["projectNotifications"] == nil
      assert [%{"message" => "not_found"}] = result["errors"]
    end
  end
end
