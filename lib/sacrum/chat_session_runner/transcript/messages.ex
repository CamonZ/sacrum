defmodule Sacrum.ChatSessionRunner.Transcript.Messages do
  @moduledoc """
  Owns idempotent persisted `ChatMessage` creation and runner message lookup.

  Public events for created messages live in the events subdomain; this module
  only creates or finds transcript rows.
  """

  alias Sacrum.Accounts.ChatMessages
  alias Sacrum.Chat.{Inference, InferenceEvents}
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @runner_version 1

  @spec list_for_session(ChatSession.t(), keyword()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def list_for_session(%ChatSession{} = session, opts) when is_list(opts) do
    ChatMessages.list_for_session(session, opts)
  end

  @spec lookup_assistant_message(ChatSession.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def lookup_assistant_message(%ChatSession{} = session) do
    with {:ok, turn_message} <- Turn.latest_user_message(session) do
      lookup_assistant_message(session, turn_message.id)
    end
  end

  @spec lookup_assistant_message(ChatSession.t(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def lookup_assistant_message(%ChatSession{} = session, turn_message_id)
      when is_binary(turn_message_id) do
    ChatMessages.get_by_client_message_id(
      session,
      Turn.assistant_client_message_id(turn_message_id)
    )
  end

  @spec assistant_message_attrs(Inference.Result.t(), String.t()) :: map()
  def assistant_message_attrs(inference_result, turn_message_id)
      when is_binary(turn_message_id) do
    InferenceEvents.assistant_message_attrs(inference_result,
      client_message_id: Turn.assistant_client_message_id(turn_message_id)
    )
  end

  @spec ensure_status_message(ChatSession.t(), atom(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  @spec ensure_status_message(ChatSession.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def ensure_status_message(%ChatSession{} = session, step, content, turn_message_id \\ nil)
      when is_atom(step) and is_binary(content) do
    turn_message_id = turn_message_id || Turn.latest_user_message_id!(session)

    attrs = %{
      role: :status,
      content: content,
      content_format: :plain,
      client_message_id: "chat_session_runner:status:#{step}:v1:#{turn_message_id}",
      metadata: %{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step),
        "turn_message_id" => turn_message_id,
        "visibility" => "internal"
      }
    }

    ensure_message(session, attrs)
  end

  @spec ensure_message(ChatSession.t(), map()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def ensure_message(%ChatSession{} = session, %{client_message_id: client_message_id} = attrs)
      when is_binary(client_message_id) do
    case ChatMessages.get_by_client_message_id(session, client_message_id) do
      {:ok, message} -> {:ok, message}
      {:error, :not_found} -> insert_idempotent_message(session, attrs, client_message_id)
    end
  end

  @spec insert_idempotent_message(ChatSession.t(), map(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, Ecto.Changeset.t() | :not_found}
  defp insert_idempotent_message(%ChatSession{} = session, attrs, client_message_id) do
    case ChatMessages.append_to_session(session, attrs) do
      {:ok, message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if unique_client_message_conflict?(changeset) do
          ChatMessages.get_by_client_message_id(session, client_message_id)
        else
          error
        end
    end
  end

  @spec unique_client_message_conflict?(Ecto.Changeset.t()) :: boolean()
  defp unique_client_message_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] == "chat_messages_chat_session_id_client_message_id_index"

      _error ->
        false
    end)
  end
end
