defmodule Sacrum.Repo.ChatMessages do
  @moduledoc """
  Database operations for public chat transcript messages.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ChatMessage

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @default_limit 100

  @spec insert(ChatSession.t(), map()) :: {:ok, ChatMessage.t()} | {:error, Ecto.Changeset.t()}
  def insert(%ChatSession{} = chat_session, attrs) when is_map(attrs) do
    %ChatMessage{
      user_id: chat_session.user_id,
      project_id: chat_session.project_id,
      chat_session_id: chat_session.id
    }
    |> ChatMessage.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec list_for_session(ChatSession.t(), keyword()) :: [ChatMessage.t()]
  def list_for_session(%ChatSession{} = chat_session, opts \\ []) when is_list(opts) do
    ChatMessage
    |> where(
      [message],
      message.user_id == ^chat_session.user_id and message.project_id == ^chat_session.project_id and
        message.chat_session_id == ^chat_session.id
    )
    |> maybe_include_private(Keyword.get(opts, :include_private, false))
    |> maybe_after(Keyword.get(opts, :after))
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> limit(^limit_option(opts))
    |> Repo.all()
  end

  @spec get_by_client_message_id(ChatSession.t(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def get_by_client_message_id(%ChatSession{} = chat_session, client_message_id)
      when is_binary(client_message_id) do
    get_by(
      conditions: [
        user_id: chat_session.user_id,
        project_id: chat_session.project_id,
        chat_session_id: chat_session.id,
        client_message_id: client_message_id
      ]
    )
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, %DateTime{} = after_inserted_at) do
    where(query, [message], message.inserted_at > ^after_inserted_at)
  end

  defp maybe_include_private(query, true), do: query

  defp maybe_include_private(query, _include_private) do
    where(
      query,
      [message],
      fragment("coalesce(?->>'visibility', 'public')", message.metadata) == "public"
    )
  end

  defp limit_option(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@default_limit)
    |> max(1)
  end
end
