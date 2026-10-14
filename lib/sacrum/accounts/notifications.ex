defmodule Sacrum.Accounts.Notifications do
  @moduledoc """
  User-scoped notification operations.

  A notification belongs to a project and its user; the database enforces that
  the project is the user's. The message Markdown is stored intact. Realtime
  delivery is the committed row's `notification_created` CDC projection, and
  marking a notification read projects `notification_updated`.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Notifications,
    preloads: [],
    default_order: [asc: :inserted_at, asc: :id]

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Notifications, as: NotificationsRepo
  alias Sacrum.Repo.Schemas.Notification

  @default_page_size 50
  @max_page_size 200

  @type page :: %{notifications: [Notification.t()], has_more: boolean()}

  @spec max_page_size() :: pos_integer()
  def max_page_size, do: @max_page_size

  @doc """
  Publish a notification to `project_id` for `user_id`.

  A project that does not exist or belongs to another user is rejected by the
  `(project_id, user_id)` foreign key.
  """
  @spec publish(String.t(), String.t(), map()) ::
          {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def publish(user_id, project_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(attrs) do
    %Notification{user_id: user_id, project_id: project_id}
    |> Notification.create_changeset(attrs)
    |> NotificationsRepo.insert()
  end

  @doc """
  Page through a project's notifications in `inserted_at`, then `id`, order.

  Options:

    * `:cursor` - the `inserted_at`/`id` of the last notification the caller
      already holds; results start strictly after it.
    * `:limit` - page size, 1 to #{@max_page_size}; defaults to #{@default_page_size}.
    * `:unread_only` - skip notifications that have been marked read.
  """
  @spec list_for_project(String.t(), String.t(), keyword()) ::
          {:ok, page()} | {:error, :not_found | :invalid_limit}
  def list_for_project(user_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(project_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_page_size)

    with :ok <- validate_limit(limit),
         {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]) do
      rows =
        NotificationsRepo.list_for_project(
          user_id,
          project_id,
          Keyword.get(opts, :cursor),
          limit + 1,
          Keyword.get(opts, :unread_only, false)
        )

      {notifications, rest} = Enum.split(rows, limit)
      {:ok, %{notifications: notifications, has_more: rest != []}}
    end
  end

  @doc """
  Mark the caller's notifications among `ids` as read.

  Idempotent: a notification keeps its first `read_at`. Unknown IDs and other
  users' notifications are ignored. Returns the caller's matching
  notifications.
  """
  @spec mark_read(String.t(), [String.t()]) ::
          {:ok, [Notification.t()]} | {:error, :invalid_id_count}
  def mark_read(user_id, ids) when is_binary(user_id) and is_list(ids) do
    ids = Enum.uniq(ids)

    case validate_limit(length(ids)) do
      :ok -> {:ok, NotificationsRepo.mark_read(user_id, ids, DateTime.utc_now())}
      {:error, :invalid_limit} -> {:error, :invalid_id_count}
    end
  end

  defp validate_limit(limit) when is_integer(limit) and limit in 1..@max_page_size, do: :ok
  defp validate_limit(_limit), do: {:error, :invalid_limit}
end
