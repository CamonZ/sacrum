defmodule Sacrum.Repo.Notifications do
  @moduledoc """
  Database operations for project notifications.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Notification

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Notification

  @type cursor :: %{inserted_at: DateTime.t(), id: String.t()}

  @doc """
  Lists up to `limit` project notifications in `inserted_at`, then `id`,
  ascending order, strictly after `cursor` when one is given. With
  `unread_only`, read notifications are skipped.
  """
  @spec list_for_project(String.t(), String.t(), cursor() | nil, pos_integer(), boolean()) ::
          [Notification.t()]
  def list_for_project(user_id, project_id, cursor, limit, unread_only)
      when is_binary(user_id) and is_binary(project_id) and is_integer(limit) and limit > 0 and
             is_boolean(unread_only) do
    Notification
    |> where([n], n.user_id == ^user_id and n.project_id == ^project_id)
    |> after_cursor(cursor)
    |> maybe_unread_only(unread_only)
    |> ordered()
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Sets `read_at` on the user's unread notifications among `ids` and returns
  every matching notification the user owns, read before or now.
  """
  @spec mark_read(String.t(), [String.t()], DateTime.t()) :: [Notification.t()]
  def mark_read(user_id, ids, %DateTime{} = read_at) when is_binary(user_id) and is_list(ids) do
    owned = where(Notification, [n], n.user_id == ^user_id and n.id in ^ids)

    Repo.update_all(where(owned, [n], is_nil(n.read_at)), set: [read_at: read_at])

    owned
    |> ordered()
    |> Repo.all()
  end

  defp ordered(query), do: order_by(query, [n], asc: n.inserted_at, asc: n.id)

  defp maybe_unread_only(query, false), do: query
  defp maybe_unread_only(query, true), do: where(query, [n], is_nil(n.read_at))

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{inserted_at: inserted_at, id: id}) do
    where(
      query,
      [n],
      n.inserted_at > ^inserted_at or (n.inserted_at == ^inserted_at and n.id > ^id)
    )
  end
end
