defmodule Sacrum.Accounts.NotificationsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Notifications
  alias Sacrum.Accounts.{Projects, Tasks}
  alias Sacrum.Repo
  alias Sacrum.Repo.Notifications, as: NotificationsRepo
  alias Sacrum.Repo.Schemas.Notification
  alias Sacrum.Repo.Users

  @inline_markdown "Artifact [report](vtb://artifact/9b7c1a52-1f0e-4f43-a0c7-2b8d7e6b1c10) " <>
                     "has been added to task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11).  \n"

  defp create_user(prefix \\ "notification") do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Notification Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp setup_project(_context) do
    user = create_user()
    %{user: user, project: create_project(user)}
  end

  defp publish(ctx, message \\ "Hello", severity \\ "info") do
    {:ok, notification} =
      Notifications.publish(ctx.user.id, ctx.project.id, %{message: message, severity: severity})

    notification
  end

  defp notification_count, do: Repo.aggregate(Notification, :count)

  describe "publish/3" do
    setup [:setup_project]

    test "stores the notification for the project and user with Markdown intact", ctx do
      assert {:ok, notification} =
               Notifications.publish(ctx.user.id, ctx.project.id, %{
                 message: @inline_markdown,
                 severity: "success"
               })

      assert notification.user_id == ctx.user.id
      assert notification.project_id == ctx.project.id
      assert notification.message == @inline_markdown
      assert notification.read_at == nil
      assert %DateTime{} = notification.inserted_at
      assert Repo.get!(Notification, notification.id).message == @inline_markdown
    end

    test "the project scope foreign key rejects another user's project", ctx do
      other = create_user("notification_other")

      assert {:error, changeset} =
               Notifications.publish(other.id, ctx.project.id, %{
                 message: "Hijack",
                 severity: "info"
               })

      assert %{project_id: ["does not exist"]} = errors_on(changeset)
      assert notification_count() == 0
    end

    test "the project scope foreign key rejects unknown projects", ctx do
      assert {:error, changeset} =
               Notifications.publish(ctx.user.id, Ecto.UUID.generate(), %{
                 message: "Missing",
                 severity: "info"
               })

      assert %{project_id: ["does not exist"]} = errors_on(changeset)
    end

    test "rejects invalid severity, blank, missing, and oversized messages", ctx do
      oversized = String.duplicate("a", Notification.max_message_bytes() + 1)

      for {attrs, field} <- [
            {%{message: "Hello", severity: "critical"}, :severity},
            {%{message: "   ", severity: "info"}, :message},
            {%{severity: "info"}, :message},
            {%{message: "Hello"}, :severity},
            {%{message: oversized, severity: "info"}, :message}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Notifications.publish(ctx.user.id, ctx.project.id, attrs)

        assert Map.has_key?(errors_on(changeset), field)
      end

      assert notification_count() == 0
    end

    test "accepts a message at the byte limit", ctx do
      message = String.duplicate("a", Notification.max_message_bytes())
      assert %Notification{message: ^message} = publish(ctx, message, "warning")
    end

    test "separate publications create separate notifications", ctx do
      assert publish(ctx, "Same").id != publish(ctx, "Same").id
    end
  end

  describe "retention" do
    setup [:setup_project]

    test "notifications are independent of tasks", ctx do
      notification = publish(ctx, "Keeps going")
      {:ok, task} = Tasks.insert(ctx.user.id, ctx.project.id, %{title: "Short-lived"})
      {:ok, _deleted} = Tasks.delete(task)

      assert Repo.get(Notification, notification.id)
    end

    test "notifications are deleted with their project", ctx do
      notification = publish(ctx, "Gone soon")
      {:ok, _deleted} = Projects.delete(ctx.project)

      refute Repo.get(Notification, notification.id)
    end
  end

  describe "list_for_project/3" do
    setup [:setup_project]

    test "pages deterministically by inserted_at then id", ctx do
      tied_at = ~U[2026-10-14 12:00:00.000000Z]

      notifications =
        for {message, inserted_at} <- [
              {"third", ~U[2026-10-14 12:00:01.000000Z]},
              {"tie-a", tied_at},
              {"tie-b", tied_at},
              {"first", ~U[2026-10-14 11:59:59.000000Z]}
            ] do
          insert_notification(ctx, message, inserted_at)
        end

      expected_ids =
        notifications
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
        |> Enum.map(& &1.id)

      assert {:ok, %{notifications: first_page, has_more: true}} =
               Notifications.list_for_project(ctx.user.id, ctx.project.id, limit: 2)

      last = List.last(first_page)

      assert {:ok, %{notifications: second_page, has_more: false}} =
               Notifications.list_for_project(ctx.user.id, ctx.project.id,
                 cursor: %{inserted_at: last.inserted_at, id: last.id},
                 limit: 2
               )

      assert Enum.map(first_page ++ second_page, & &1.id) == expected_ids
    end

    test "does not leak notifications across projects or users", ctx do
      publish(ctx, "mine")
      sibling = %{ctx | project: create_project(ctx.user, "Sibling")}
      publish(sibling, "sibling")

      assert {:ok, %{notifications: [%Notification{message: "mine"}]}} =
               Notifications.list_for_project(ctx.user.id, ctx.project.id)

      other = create_user("notification_other")
      assert {:error, :not_found} = Notifications.list_for_project(other.id, ctx.project.id)
    end

    test "rejects out-of-range limits", ctx do
      for limit <- [0, Notifications.max_page_size() + 1] do
        assert {:error, :invalid_limit} =
                 Notifications.list_for_project(ctx.user.id, ctx.project.id, limit: limit)
      end
    end
  end

  describe "mark_read/2" do
    setup [:setup_project]

    test "marks notifications read once and filters them from unread history", ctx do
      first = publish(ctx, "first")
      second = publish(ctx, "second")

      assert {:ok, [%Notification{id: first_id, read_at: %DateTime{} = read_at}]} =
               Notifications.mark_read(ctx.user.id, [first.id, first.id])

      assert first_id == first.id

      assert {:ok, [%Notification{read_at: ^read_at}]} =
               Notifications.mark_read(ctx.user.id, [first.id])

      assert {:ok, %{notifications: [%Notification{id: unread_id}]}} =
               Notifications.list_for_project(ctx.user.id, ctx.project.id, unread_only: true)

      assert unread_id == second.id

      assert {:ok, %{notifications: [_, _]}} =
               Notifications.list_for_project(ctx.user.id, ctx.project.id)
    end

    test "ignores unknown IDs and other users' notifications", ctx do
      notification = publish(ctx, "mine")
      other = create_user("notification_other")

      assert {:ok, []} =
               Notifications.mark_read(other.id, [notification.id, Ecto.UUID.generate()])

      assert Repo.get!(Notification, notification.id).read_at == nil
    end

    test "requires between 1 and the page size of IDs", ctx do
      too_many = for _ <- 0..Notifications.max_page_size(), do: Ecto.UUID.generate()

      assert {:error, :invalid_id_count} = Notifications.mark_read(ctx.user.id, [])
      assert {:error, :invalid_id_count} = Notifications.mark_read(ctx.user.id, too_many)
    end
  end

  defp insert_notification(ctx, message, inserted_at) do
    {:ok, notification} =
      %Notification{user_id: ctx.user.id, project_id: ctx.project.id, inserted_at: inserted_at}
      |> Notification.create_changeset(%{message: message, severity: "info"})
      |> NotificationsRepo.insert()

    notification
  end
end
