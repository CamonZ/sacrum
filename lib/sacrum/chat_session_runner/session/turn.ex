defmodule Sacrum.ChatSessionRunner.Session.Turn do
  @moduledoc """
  Owns turn-oriented chat message lookup and ordering for the session runner.

  This module is deliberately limited to identifying the current user turn,
  deriving runner-owned assistant client IDs, and ordering persisted messages.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"

  @spec latest_user_message(ChatSession.t()) :: {:ok, ChatMessage.t()} | {:error, :not_found}
  def latest_user_message(%ChatSession{} = session) do
    latest_message_by_role(session, :user)
  end

  @spec latest_user_message_id!(ChatSession.t()) :: String.t()
  def latest_user_message_id!(%ChatSession{} = session) do
    case latest_user_message(session) do
      {:ok, message} -> message.id
      {:error, :not_found} -> raise ArgumentError, "chat session has no user message"
    end
  end

  @spec get_message(ChatSession.t(), String.t()) :: {:ok, ChatMessage.t()} | {:error, :not_found}
  def get_message(%ChatSession{} = session, message_id) when is_binary(message_id) do
    query =
      from message in ChatMessage,
        where:
          message.user_id == ^session.user_id and message.project_id == ^session.project_id and
            message.chat_session_id == ^session.id and message.id == ^message_id,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec turn_message_id([ChatMessage.t()]) :: String.t() | nil
  def turn_message_id(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      %ChatMessage{id: id} -> id
      nil -> nil
    end
  end

  @spec assistant_client_message_id(String.t()) :: String.t()
  def assistant_client_message_id(turn_message_id) when is_binary(turn_message_id) do
    "#{@assistant_client_message_id_prefix}:#{turn_message_id}"
  end

  @spec turn_message_id_from_assistant(ChatMessage.t()) :: String.t() | nil
  def turn_message_id_from_assistant(%ChatMessage{client_message_id: client_message_id})
      when is_binary(client_message_id) do
    prefix = "#{@assistant_client_message_id_prefix}:"

    if String.starts_with?(client_message_id, prefix) do
      String.replace_prefix(client_message_id, prefix, "")
    end
  end

  def turn_message_id_from_assistant(_message), do: nil

  @spec compare_messages(ChatMessage.t(), ChatMessage.t()) :: :lt | :eq | :gt
  def compare_messages(%ChatMessage{} = left, %ChatMessage{} = right) do
    case DateTime.compare(left.inserted_at, right.inserted_at) do
      :eq -> compare_ids(left.id, right.id)
      comparison -> comparison
    end
  end

  @spec latest_message_by_role(ChatSession.t(), atom()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  defp latest_message_by_role(%ChatSession{} = session, role) do
    query =
      from message in ChatMessage,
        where:
          message.user_id == ^session.user_id and message.project_id == ^session.project_id and
            message.chat_session_id == ^session.id and message.role == ^role,
        order_by: [desc: message.inserted_at, desc: message.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec compare_ids(String.t(), String.t()) :: :lt | :eq | :gt
  defp compare_ids(left_id, right_id) do
    cond do
      left_id > right_id -> :gt
      left_id < right_id -> :lt
      true -> :eq
    end
  end
end
