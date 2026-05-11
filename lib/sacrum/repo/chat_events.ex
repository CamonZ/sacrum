defmodule Sacrum.Repo.ChatEvents do
  @moduledoc """
  Database operations for V0 chat events.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ChatEvent

  import Ecto.Query
  alias Sacrum.Chat.PublicEvents
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

  @spec get_by_type(ChatSession.t(), String.t(), :public | :internal) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  def get_by_type(%ChatSession{} = chat_session, event_type, visibility)
      when is_binary(event_type) and visibility in [:public, :internal] do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^chat_session.user_id and
            event.project_id == ^chat_session.project_id and
            event.chat_session_id == ^chat_session.id and
            event.event_type == ^event_type and
            event.visibility == ^visibility,
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @spec get_message_created_for_message(ChatSession.t(), String.t()) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  def get_message_created_for_message(%ChatSession{} = chat_session, message_id)
      when is_binary(message_id) do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^chat_session.user_id and
            event.project_id == ^chat_session.project_id and
            event.chat_session_id == ^chat_session.id and
            event.event_type == ^PublicEvents.event_type(:message_created) and
            event.visibility == :public and
            fragment("?->>'id' = ?", event.public_payload, ^message_id),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
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
