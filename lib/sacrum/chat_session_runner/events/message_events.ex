defmodule Sacrum.ChatSessionRunner.Events.MessageEvents do
  @moduledoc """
  Owns idempotent public events for newly visible chat messages.
  """

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  @spec ensure_public_message_event(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def ensure_public_message_event(%ChatSession{} = session, %ChatMessage{} = message) do
    case ChatEvents.get_message_created_for_message(session, message.id) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        ChatEvents.append_to_session(session, PublicEvents.message_created_attrs(message))
    end
  end
end
