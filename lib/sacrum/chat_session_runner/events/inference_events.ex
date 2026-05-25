defmodule Sacrum.ChatSessionRunner.Events.InferenceEvents do
  @moduledoc """
  Owns inference-completed event persistence and resume lookup.
  """

  import Ecto.Query

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.Inference
  alias Sacrum.Chat.InferenceEvents, as: InferenceEventAttrs
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  @spec append_inference_completed_event(ChatSession.t(), ChatMessage.t(), Inference.Result.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def append_inference_completed_event(
        %ChatSession{} = session,
        %ChatMessage{} = message,
        %Inference.Result{} = inference_result
      ) do
    attrs = InferenceEventAttrs.inference_completed_attrs(message, inference_result)
    ensure_inference_completed_event(session, attrs)
  end

  @spec ensure_resumed_inference_completed_event(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def ensure_resumed_inference_completed_event(%ChatSession{} = session, %ChatMessage{} = message) do
    attrs = InferenceEventAttrs.resumed_inference_completed_attrs(message)
    ensure_inference_completed_event(session, attrs)
  end

  @spec ensure_inference_completed_event(ChatSession.t(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def ensure_inference_completed_event(%ChatSession{} = session, attrs) when is_map(attrs) do
    assistant_message_id = attrs.internal_payload["assistant_message_id"]

    case get_inference_completed_for_assistant(session, assistant_message_id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> ChatEvents.append_to_session(session, attrs)
    end
  end

  @spec get_inference_completed_for_assistant(ChatSession.t(), String.t() | nil) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  def get_inference_completed_for_assistant(%ChatSession{} = session, assistant_message_id)
      when is_binary(assistant_message_id) do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^session.user_id and event.project_id == ^session.project_id and
            event.chat_session_id == ^session.id and
            event.event_type == ^InferenceEventAttrs.event_type(:inference_completed) and
            event.visibility == :internal and
            fragment(
              "?->>'assistant_message_id' = ?",
              event.internal_payload,
              ^assistant_message_id
            ),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  def get_inference_completed_for_assistant(%ChatSession{}, _assistant_message_id),
    do: {:error, :not_found}
end
