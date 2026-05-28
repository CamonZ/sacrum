defmodule Sacrum.Accounts.LiveChat do
  @moduledoc """
  Public V0 live chat operations used by GraphQL.

  This layer composes chat sessions, messages, and persisted public chat events.
  It intentionally stays session-first and does not create chat runs, artifacts,
  or task links. Runner orchestration stays outside chat persistence
  transactions so committed messages remain the source of truth.
  """

  alias Sacrum.Accounts.{
    AuthoringChatLoop,
    ChatEvents,
    ChatMessages,
    ChatSessions
  }

  alias Sacrum.Chat.{Inference, InferenceEvents, PublicEvents}
  alias Sacrum.ChatSessionRunner.Actions, as: RunnerActions
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.ChatSessionSupervisor
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @spec create_session(String.t(), String.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def create_session(user_id, project_id, attrs \\ %{}) when is_map(attrs) do
    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.insert(user_id, project_id, attrs),
           {:ok, event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.session_created_attrs(session)
             ) do
        {session, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec send_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def send_message(user_id, project_id, chat_session_id, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> put_default(:role, "role", :user)
      |> put_default(:content_format, "content_format", ChatMessage.default_content_format())

    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
           {:ok, message} <- ChatMessages.append_to_session(session, attrs),
           {:ok, event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ) do
        {message, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec send_message_and_start_runner(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def send_message_and_start_runner(user_id, project_id, chat_session_id, attrs, opts \\ [])
      when is_map(attrs) and is_list(opts) do
    with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
         :ok <- prepare_runner_for_user_turn(session) do
      message_id = Ecto.UUID.generate()

      signal =
        RunnerActions.user_turn_signal(
          user_turn_signal_data(user_id, project_id, chat_session_id, message_id, attrs, opts)
        )

      case start_or_cast_user_turn(chat_session_id, signal, opts) do
        {:ok, _pid} ->
          {:ok, accepted_turn_response(user_id, project_id, chat_session_id, message_id, attrs)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec run_inference(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def run_inference(user_id, project_id, chat_session_id, opts \\ []) when is_list(opts) do
    with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
         {:ok, messages} <- ChatMessages.list_for_session(session, []),
         {:ok, inference_result} <- Inference.generate(messages, opts) do
      persist_assistant_result(session, inference_result)
    end
  end

  @spec cancel_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def cancel_session(user_id, project_id, chat_session_id) do
    with {:ok, updated_session} <-
           persist_session_cancellation(user_id, project_id, chat_session_id),
         :ok <- terminate_runner_if_running(chat_session_id) do
      {:ok, updated_session}
    end
  end

  @spec delete_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def delete_session(user_id, project_id, chat_session_id) do
    with {:ok, deleted_session} <-
           ChatSessions.delete_session(user_id, project_id, chat_session_id),
         :ok <- terminate_runner_if_running(chat_session_id) do
      {:ok, deleted_session}
    end
  end

  @spec get_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def get_session(user_id, project_id, chat_session_id) do
    ChatSessions.get_session(user_id, project_id, chat_session_id)
  end

  @spec list_sessions(String.t(), String.t(), keyword()) :: [ChatSession.t()]
  def list_sessions(user_id, project_id, opts \\ []) do
    ChatSessions.list_sessions(user_id, project_id, opts)
  end

  @spec list_messages(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def list_messages(user_id, project_id, chat_session_id, opts \\ []) do
    ChatMessages.list_for_session(user_id, project_id, chat_session_id, opts)
  end

  @spec list_public_events(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_public_events(user_id, project_id, chat_session_id, opts \\ []) do
    ChatEvents.list_public_for_session(user_id, project_id, chat_session_id, opts)
  end

  defp transaction_result(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, _event}} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_or_cast_user_turn(chat_session_id, signal, opts) when is_binary(chat_session_id) do
    runner = Keyword.get(opts, :runner, ChatSessionSupervisor)
    start_opts = Keyword.get(opts, :start_opts, live_chat_runner_start_opts())

    runner.start_or_cast_user_turn(chat_session_id, signal, start_opts)
  end

  defp prepare_runner_for_user_turn(%ChatSession{status: status, id: chat_session_id})
       when status in [:completed, :failed] do
    terminate_runner_if_running(chat_session_id)
  end

  defp prepare_runner_for_user_turn(%ChatSession{}), do: :ok

  defp persist_session_cancellation(user_id, project_id, chat_session_id) do
    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
           :ok <- ensure_stoppable(session),
           {:ok, updated_session} <-
             ChatSessions.update_session(session, %{
               status: :cancelled,
               stop_requested_at: session.stop_requested_at || DateTime.utc_now()
             }),
           {:ok, event} <-
             ChatEvents.append_to_session(
               updated_session,
               PublicEvents.session_updated_attrs(updated_session)
             ) do
        {updated_session, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp terminate_runner_if_running(chat_session_id) do
    case ChatSessionSupervisor.terminate_runner(chat_session_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp user_turn_signal_data(user_id, project_id, chat_session_id, message_id, attrs, opts) do
    attrs = accepted_user_turn_attrs(attrs)

    %{
      message_id: message_id,
      user_id: user_id,
      project_id: project_id,
      chat_session_id: chat_session_id,
      engine_session_ref: Sacrum.ChatSessionRunner.agent_id(chat_session_id),
      inference_opts: user_turn_inference_opts(opts)
    }
    |> Map.merge(attrs)
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
    |> Map.new()
  end

  defp accepted_turn_response(user_id, project_id, chat_session_id, message_id, attrs) do
    attrs = accepted_user_turn_attrs(attrs)

    Map.merge(attrs, %{
      id: message_id,
      user_id: user_id,
      project_id: project_id,
      chat_session_id: chat_session_id,
      role: :user
    })
  end

  defp accepted_user_turn_attrs(attrs) do
    attrs =
      put_default(attrs, :content_format, "content_format", ChatMessage.default_content_format())

    %{
      content: fetch_attr(attrs, :content, "content"),
      content_format:
        normalize_content_format(fetch_attr(attrs, :content_format, "content_format")),
      client_message_id: fetch_attr(attrs, :client_message_id, "client_message_id"),
      metadata: safe_metadata(fetch_attr(attrs, :metadata, "metadata") || %{})
    }
  end

  defp fetch_attr(attrs, atom_key, string_key) do
    cond do
      Map.has_key?(attrs, atom_key) -> Map.fetch!(attrs, atom_key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  defp safe_metadata(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, metadata_value}, metadata ->
      with true <- is_binary(key),
           {:ok, safe_value} <- safe_metadata_value(metadata_value) do
        Map.put(metadata, key, safe_value)
      else
        _other -> metadata
      end
    end)
  end

  defp safe_metadata(_value), do: %{}

  defp safe_metadata_value(value) when is_binary(value) or is_boolean(value) or is_number(value),
    do: {:ok, value}

  defp safe_metadata_value(nil), do: {:ok, nil}

  defp safe_metadata_value(value) when is_list(value) do
    safe_list =
      value
      |> Enum.reduce([], fn item, items ->
        case safe_metadata_value(item) do
          {:ok, safe_item} -> [safe_item | items]
          :error -> items
        end
      end)
      |> Enum.reverse()

    {:ok, safe_list}
  end

  defp safe_metadata_value(value) when is_map(value), do: {:ok, safe_metadata(value)}
  defp safe_metadata_value(_value), do: :error

  defp normalize_content_format(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_content_format(value), do: value

  defp user_turn_inference_opts(opts) do
    opts
    |> Keyword.get(:inference_opts, Keyword.get(opts[:start_opts] || [], :inference_opts))
    |> case do
      nil -> Keyword.get(live_chat_runner_start_opts(), :inference_opts, [])
      inference_opts -> inference_opts
    end
  end

  @spec live_chat_runner_start_opts() :: keyword()
  defp live_chat_runner_start_opts do
    :sacrum
    |> Application.get_env(:live_chat_runner, [])
    |> Keyword.get(:start_opts, [])
  end

  defp persist_assistant_result(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    transaction_result(fn ->
      with {:ok, message} <-
             ChatMessages.append_to_session(
               session,
               InferenceEvents.assistant_message_attrs(inference_result)
             ),
           {:ok, public_event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ),
           {:ok, _internal_event} <-
             ChatEvents.append_to_session(
               session,
               InferenceEvents.inference_completed_attrs(message, inference_result)
             ),
           :ok <- AuthoringChatLoop.apply_inference_result(session, inference_result) do
        {message, public_event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_stoppable(%ChatSession{status: status}) do
    if ChatSessionStatus.stoppable?(status) do
      :ok
    else
      {:error, "Cannot cancel chat session with status #{ChatSessionStatus.wire_value(status)}"}
    end
  end

  defp put_default(attrs, atom_key, string_key, value) do
    if Map.has_key?(attrs, atom_key) or Map.has_key?(attrs, string_key) do
      attrs
    else
      Map.put(attrs, atom_key, value)
    end
  end
end
