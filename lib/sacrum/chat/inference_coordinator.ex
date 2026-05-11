defmodule Sacrum.Chat.InferenceCoordinator do
  @moduledoc """
  Coordinates asynchronous chat inference after user messages are persisted.

  The application supervises one lightweight GenServer per `chat_session_id`
  under `Sacrum.Chat.InferenceSupervisor`, with
  `Sacrum.Chat.InferenceRegistry` enforcing a unique coordinator per session.
  Each coordinator starts provider work under `Sacrum.Chat.InferenceTaskSupervisor`
  and keeps processing trigger casts while the provider task is running. Triggers
  received during a run are coalesced into one pending rerun, which guarantees at
  most one in-flight inference per chat session while still processing the latest
  transcript after the active run completes.
  """

  use GenServer

  require Logger

  alias Sacrum.Accounts.{ChatEvents, ChatSessions, LiveChat}
  alias Sacrum.Chat.InferenceEvents
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @registry Sacrum.Chat.InferenceRegistry
  @supervisor Sacrum.Chat.InferenceSupervisor
  @task_supervisor Sacrum.Chat.InferenceTaskSupervisor
  @default_idle_timeout 5_000

  defstruct [:chat_session_id, :user_id, :project_id, :opts, :task_ref, pending?: false]

  @type enqueue_result :: :ok | {:error, term()}

  @doc """
  Schedules asynchronous inference for a chat session.

  The call returns after enqueueing work; it never waits for the inference
  provider. Multiple enqueue calls for the same session share one coordinator.
  """
  @spec enqueue(String.t(), String.t(), String.t(), keyword()) :: enqueue_result()
  def enqueue(user_id, project_id, chat_session_id, opts \\ []) when is_list(opts) do
    child_opts = [
      user_id: user_id,
      project_id: project_id,
      chat_session_id: chat_session_id,
      opts: opts
    ]

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, child_opts}) do
      {:ok, pid} ->
        cast_enqueue(pid, user_id, project_id, opts)

      {:error, {:already_started, pid}} ->
        cast_enqueue(pid, user_id, project_id, opts)

      {:error, reason} = error ->
        Logger.warning(
          "Failed to start chat inference coordinator for session #{chat_session_id}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(chat_session_id))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)

    %{
      id: {__MODULE__, chat_session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       chat_session_id: Keyword.fetch!(opts, :chat_session_id),
       user_id: Keyword.fetch!(opts, :user_id),
       project_id: Keyword.fetch!(opts, :project_id),
       opts: Keyword.get(opts, :opts, [])
     }}
  end

  @impl true
  def handle_cast({:enqueue, user_id, project_id, opts}, %__MODULE__{task_ref: nil} = state) do
    state =
      state
      |> put_latest_trigger(user_id, project_id, opts)
      |> start_inference_task()

    {:noreply, state}
  end

  def handle_cast({:enqueue, user_id, project_id, opts}, %__MODULE__{} = state) do
    {:noreply,
     state
     |> put_latest_trigger(user_id, project_id, opts)
     |> Map.put(:pending?, true)}
  end

  @impl true
  def handle_info({ref, result}, %__MODULE__{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    finish_inference_task(result, %{state | task_ref: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{task_ref: ref} = state) do
    Logger.warning(
      "Chat inference task crashed for session #{state.chat_session_id}: #{inspect(reason)}"
    )

    finish_inference_task({:error, {:task_crashed, reason}}, %{state | task_ref: nil})
  end

  def handle_info(:timeout, %__MODULE__{task_ref: nil} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:timeout, %__MODULE__{} = state), do: {:noreply, state}

  def handle_info(_message, %__MODULE__{} = state), do: {:noreply, state}

  defp cast_enqueue(pid, user_id, project_id, opts) do
    GenServer.cast(pid, {:enqueue, user_id, project_id, opts})
    :ok
  end

  defp via_tuple(chat_session_id) do
    {:via, Registry, {@registry, chat_session_id}}
  end

  defp put_latest_trigger(%__MODULE__{} = state, user_id, project_id, opts) do
    %{state | user_id: user_id, project_id: project_id, opts: opts}
  end

  defp start_inference_task(%__MODULE__{} = state) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        run_once(state.user_id, state.project_id, state.chat_session_id, state.opts)
      end)

    %{state | task_ref: task.ref, pending?: false}
  end

  defp finish_inference_task(_result, %__MODULE__{pending?: true} = state) do
    {:noreply, start_inference_task(%{state | pending?: false})}
  end

  defp finish_inference_task(_result, %__MODULE__{} = state) do
    {:noreply, state, idle_timeout()}
  end

  defp run_once(user_id, project_id, chat_session_id, opts) do
    case ChatSessions.get_session(user_id, project_id, chat_session_id) do
      {:ok, session} ->
        session
        |> LiveChat.run_inference_for_session(opts)
        |> handle_inference_result(session)

      {:error, :not_found} = skipped ->
        skipped
    end
  rescue
    exception ->
      reason = {:exception, Exception.message(exception)}
      record_failure(user_id, project_id, chat_session_id, reason)
      {:error, reason}
  catch
    kind, reason ->
      caught = {kind, reason}
      record_failure(user_id, project_id, chat_session_id, caught)
      {:error, caught}
  end

  defp handle_inference_result({:ok, %ChatMessage{id: message_id}}, _session) do
    {:ok, message_id}
  end

  defp handle_inference_result(
         {:error, {:chat_session_not_runnable, _status}} = skipped,
         _session
       ) do
    skipped
  end

  defp handle_inference_result({:error, reason} = error, %ChatSession{} = session) do
    record_failure(session, reason)
    error
  end

  defp record_failure(user_id, project_id, chat_session_id, reason) do
    case ChatSessions.get_session(user_id, project_id, chat_session_id) do
      {:ok, %ChatSession{} = session} -> record_failure(session, reason)
      {:error, _reason} -> :ok
    end
  end

  defp record_failure(%ChatSession{} = session, reason) do
    failed_attrs = InferenceEvents.failed_attrs(reason)

    Logger.warning(
      "Chat inference failed for session #{session.id}: #{inspect(failed_attrs.internal_payload["error"])}"
    )

    session
    |> ChatEvents.append_to_session(failed_attrs)
    |> case do
      {:ok, _event} ->
        :ok

      {:error, append_reason} ->
        Logger.warning(
          "Failed to append chat_inference.failed for session #{session.id}: #{inspect(append_reason)}"
        )

        :ok
    end
  end

  defp idle_timeout do
    :sacrum
    |> Application.get_env(:chat_inference, [])
    |> Keyword.get(:coordinator_idle_timeout, @default_idle_timeout)
  end
end
