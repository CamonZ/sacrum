defmodule SacrumWeb.Graphql.Types.NotificationTypes do
  @moduledoc """
  GraphQL type definitions for project notifications.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts

  object :notification do
    field :id, :id
    field :project_id, :id

    field :message, :string do
      description("Daemon-authored Markdown, stored and returned exactly as published.")
    end

    field :severity, :string do
      description("One of info, success, warning, or error.")
    end

    field :inserted_at, :datetime

    field :read_at, :datetime do
      description("When the owner marked the notification read; null while unread.")
    end
  end

  object :notification_page do
    field :notifications, list_of(:notification)

    field :has_more, :boolean do
      description("True when more notifications follow the last returned one.")
    end
  end

  object :notification_queries do
    @desc """
    Project notifications ordered by insertedAt, then id, ascending. Pass the
    insertedAt and id of the last notification already held to resume after it.
    Set unreadOnly to skip notifications that have been marked read.
    """
    field :project_notifications, :notification_page do
      arg(:project_id, non_null(:uuid4))
      arg(:after_inserted_at, :datetime)
      arg(:after_id, :uuid4)
      arg(:limit, :integer, default_value: 50)
      arg(:unread_only, :boolean, default_value: false)

      resolve(fn %{project_id: project_id} = args, %{context: %{current_user: user}} ->
        with {:ok, cursor} <- cursor(args) do
          user.id
          |> Accounts.Notifications.list_for_project(project_id,
            cursor: cursor,
            limit: args.limit,
            unread_only: args.unread_only
          )
          |> list_result()
        end
      end)
    end
  end

  object :notification_mutations do
    @desc "Publish a Markdown notification to one of the caller's projects."
    field :publish_notification, :notification do
      arg(:project_id, non_null(:uuid4))
      arg(:message, non_null(:string))
      arg(:severity, non_null(:string))

      resolve(fn %{project_id: project_id} = args, %{context: %{current_user: user}} ->
        Accounts.Notifications.publish(
          user.id,
          project_id,
          Map.take(args, [:message, :severity])
        )
      end)
    end

    @desc """
    Mark notifications read. Idempotent: each keeps its first readAt. Unknown
    IDs and other users' notifications are ignored.
    """
    field :mark_notifications_read, list_of(:notification) do
      arg(:ids, non_null(list_of(non_null(:uuid4))))

      resolve(fn %{ids: ids}, %{context: %{current_user: user}} ->
        case Accounts.Notifications.mark_read(user.id, ids) do
          {:error, :invalid_id_count} ->
            {:error,
             "ids must contain between 1 and #{Accounts.Notifications.max_page_size()} notification IDs"}

          result ->
            result
        end
      end)
    end
  end

  defp cursor(%{after_inserted_at: inserted_at, after_id: id}),
    do: {:ok, %{inserted_at: inserted_at, id: id}}

  defp cursor(%{after_inserted_at: _}),
    do: {:error, "afterInsertedAt and afterId must be provided together"}

  defp cursor(%{after_id: _}),
    do: {:error, "afterInsertedAt and afterId must be provided together"}

  defp cursor(_args), do: {:ok, nil}

  defp list_result({:error, :invalid_limit}),
    do: {:error, "limit must be between 1 and #{Accounts.Notifications.max_page_size()}"}

  defp list_result(result), do: result
end
