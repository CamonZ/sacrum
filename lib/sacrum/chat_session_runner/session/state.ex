defmodule Sacrum.ChatSessionRunner.Session.State do
  @moduledoc """
  Owns chat session fetching, runnable checks, status transitions, and failure surfacing.
  """

  alias Sacrum.Accounts.{ChatEvents, ChatSessions}
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.ChatSessionRunner.Events.Checkpoints
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.ChatSessionRunner.Transcript.Messages
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @engine_kind "jido"

  @spec fetch_session(String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def fetch_session(chat_session_id) when is_binary(chat_session_id) do
    ChatSessionsRepo.get(chat_session_id)
  end

  @spec ensure_runnable(ChatSession.t()) ::
          {:continue, ChatSession.t()} | {:halt, ChatSession.t(), term()}
  def ensure_runnable(%ChatSession{} = session) do
    cond do
      session.status in [:cancelled, :cancelling] ->
        {:halt, session, {:terminal_status, session.status}}

      session.status in [:completed, :failed] ->
        if pending_user_turn?(session) do
          {:continue, session}
        else
          {:halt, session, {:terminal_status, session.status}}
        end

      ChatSessionStatus.terminal?(session.status) ->
        {:halt, session, {:terminal_status, session.status}}

      true ->
        {:continue, session}
    end
  end

  @spec refresh_runnable_session(ChatSession.t()) ::
          {:ok, ChatSession.t()}
          | {:halt, ChatSession.t(), term()}
          | {:error, term()}
  def refresh_runnable_session(%ChatSession{} = session) do
    with {:ok, refreshed_session} <- ChatSessionsRepo.get(session.id),
         {:continue, refreshed_session} <- ensure_runnable(refreshed_session) do
      {:ok, refreshed_session}
    end
  end

  @spec ensure_running_session(ChatSession.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def ensure_running_session(
        %ChatSession{
          status: :running,
          engine_kind: @engine_kind,
          engine_session_ref: engine_session_ref
        } = session,
        engine_session_ref
      ) do
    {:ok, session}
  end

  def ensure_running_session(%ChatSession{status: :running} = session, engine_session_ref)
      when is_binary(engine_session_ref) do
    update_session_with_event(session, %{
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  def ensure_running_session(%ChatSession{} = session, engine_session_ref)
      when is_binary(engine_session_ref) do
    update_session_with_event(session, %{
      status: :running,
      ended_at: nil,
      stop_requested_at: nil,
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  @spec ensure_completed_session(ChatSession.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def ensure_completed_session(%ChatSession{status: :completed} = session), do: {:ok, session}

  def ensure_completed_session(%ChatSession{} = session) do
    update_session_with_event(session, %{status: :completed})
  end

  @spec pending_user_turn_after?(ChatSession.t(), String.t() | nil) :: boolean()
  def pending_user_turn_after?(%ChatSession{}, nil), do: false

  def pending_user_turn_after?(%ChatSession{} = session, turn_message_id)
      when is_binary(turn_message_id) do
    with {:ok, turn_message} <- Turn.get_message(session, turn_message_id),
         {:ok, latest_user} <- Turn.latest_user_message(session) do
      latest_user.id != turn_message.id and
        Turn.compare_messages(latest_user, turn_message) == :gt and
        match?({:error, :not_found}, Messages.lookup_assistant_message(session, latest_user.id))
    else
      {:error, :not_found} -> false
    end
  end

  @spec surface_failure(String.t(), term()) :: :ok | {:error, term()}
  def surface_failure(chat_session_id, reason) when is_binary(chat_session_id) do
    case ChatSessionsRepo.get(chat_session_id) do
      {:ok, %ChatSession{} = session} ->
        failed_reason = inspect(reason)

        with {:continue, session} <- ensure_runnable(session),
             {:ok, failed_session} <- update_session_with_event(session, %{status: :failed}),
             {:ok, _events} <-
               Checkpoints.checkpoint_step(failed_session, :failed, %{"reason" => failed_reason}) do
          :ok
        else
          {:halt, _session, _reason} -> :ok
          {:error, failure_reason} -> {:error, failure_reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec mark_failed(String.t(), term()) :: {:error, term()}
  def mark_failed(chat_session_id, reason) when is_binary(chat_session_id) do
    case surface_failure(chat_session_id, reason) do
      :ok -> {:error, reason}
      {:error, _failure_reason} -> {:error, reason}
    end
  end

  @spec update_session_with_event(ChatSession.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  defp update_session_with_event(%ChatSession{} = session, attrs) do
    case Repo.transaction(fn -> update_session_and_event!(session, attrs) end) do
      {:ok, {updated_session, _event}} ->
        {:ok, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_session_and_event!(ChatSession.t(), map()) :: {ChatSession.t(), ChatEvent.t()}
  defp update_session_and_event!(%ChatSession{} = session, attrs) do
    with {:ok, updated_session} <- ChatSessions.update_session(session, attrs),
         {:ok, event} <-
           ChatEvents.append_to_session(
             updated_session,
             PublicEvents.session_updated_attrs(updated_session)
           ) do
      {updated_session, event}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec pending_user_turn?(ChatSession.t()) :: boolean()
  defp pending_user_turn?(%ChatSession{} = session) do
    case Turn.latest_user_message(session) do
      {:ok, user_message} ->
        case Messages.lookup_assistant_message(session, user_message.id) do
          {:ok, _assistant_message} -> false
          {:error, :not_found} -> true
        end

      {:error, :not_found} ->
        false
    end
  end
end
