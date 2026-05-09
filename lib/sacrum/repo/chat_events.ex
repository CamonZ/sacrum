defmodule Sacrum.Repo.ChatEvents do
  @moduledoc """
  Database operations for V0 chat events.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ChatEvent

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @default_limit 100

  @spec insert(ChatSession.t(), map()) :: {:ok, ChatEvent.t()} | {:error, Ecto.Changeset.t()}
  def insert(%ChatSession{} = chat_session, attrs) when is_map(attrs) do
    %ChatEvent{
      user_id: chat_session.user_id,
      project_id: chat_session.project_id,
      chat_session_id: chat_session.id
    }
    |> ChatEvent.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec list_public_for_session(ChatSession.t(), keyword()) :: [map()]
  def list_public_for_session(%ChatSession{} = chat_session, opts \\ []) when is_list(opts) do
    ChatEvent
    |> where(
      [event],
      event.user_id == ^chat_session.user_id and event.project_id == ^chat_session.project_id and
        event.chat_session_id == ^chat_session.id and event.visibility == :public
    )
    |> maybe_after(Keyword.get(opts, :after))
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> limit(^limit_option(opts))
    |> select([event], %{
      id: event.id,
      user_id: event.user_id,
      project_id: event.project_id,
      chat_session_id: event.chat_session_id,
      event_type: event.event_type,
      visibility: event.visibility,
      public_payload: event.public_payload,
      inserted_at: event.inserted_at
    })
    |> Repo.all()
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, %DateTime{} = after_inserted_at) do
    where(query, [event], event.inserted_at > ^after_inserted_at)
  end

  defp limit_option(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@default_limit)
    |> max(1)
  end
end
