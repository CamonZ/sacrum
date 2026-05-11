defmodule Sacrum.ChatSessionRunner.Actions.RunOnce do
  @moduledoc false

  use Jido.Action,
    name: "sacrum_chat_session_run_once",
    description: "Run one persisted Sacrum chat session assistant turn",
    category: "chat",
    tags: ["sacrum", "chat", "session"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []]
    ],
    output_schema: [
      status: [type: :atom, required: true],
      last_answer: [type: :any],
      error: [type: :any]
    ]

  @impl true
  def run(params, _context) do
    opts = [
      engine_session_ref: params.engine_session_ref,
      inference_opts: params.inference_opts
    ]

    case Sacrum.ChatSessionRunner.run_once(params.chat_session_id, opts) do
      {:ok, result} ->
        {:ok, %{status: :completed, last_answer: result}}

      {:error, reason} ->
        {:ok, %{status: :failed, error: reason}}
    end
  end
end

defmodule Sacrum.ChatSessionRunner do
  @moduledoc """
  Runs one persisted chat session through a single assistant turn.

  The runner is deliberately session-first. It consumes `ChatSession`,
  `ChatMessage`, and `ChatEvent` rows, calls the Sacrum chat inference boundary,
  and checkpoints public/internal progress without creating tasks, artifacts,
  harness requests, `ChatRun`, or Runic state.
  """

  use Jido.Agent,
    name: "sacrum_chat_session_runner",
    description: "Runs one persisted Sacrum chat session assistant turn",
    category: "chat",
    tags: ["sacrum", "chat", "session"],
    vsn: "1.0.0",
    schema: [
      status: [type: :atom, default: :idle],
      chat_session_id: [type: :string],
      engine_session_ref: [type: :string],
      inference_opts: [type: :any, default: []]
    ],
    signal_routes: [
      {"sacrum.chat_session.run", Sacrum.ChatSessionRunner.Actions.RunOnce}
    ]

  require Logger

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Chat.{Inference, InferenceEvents, PublicEvents}
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @engine_kind "jido"
  @engine_session_ref_prefix "jido_agent_server:"
  @runner_version 1
  @assistant_client_message_id "chat_session_runner:assistant:v1"
  @completion_cleanup_delay_ms 100
  @run_signal_type "sacrum.chat_session.run"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)
    inference_opts = Keyword.get(opts, :inference_opts, [])
    engine_session_ref = agent_id(chat_session_id)

    agent_opts = [
      agent: __MODULE__,
      id: engine_session_ref,
      initial_state: %{
        status: :idle,
        chat_session_id: chat_session_id,
        engine_session_ref: engine_session_ref,
        inference_opts: inference_opts
      },
      register_global: false,
      name: Sacrum.ChatSessionRegistry.via_tuple(chat_session_id)
    ]

    with {:ok, pid} <- Jido.AgentServer.start_link(agent_opts),
         :ok <-
           Jido.AgentServer.cast(
             pid,
             run_signal(chat_session_id, engine_session_ref, inference_opts)
           ) do
      start_completion_cleanup(pid)
      {:ok, pid}
    else
      {:error, reason} = error ->
        Logger.error("[ChatSessionRunner:#{chat_session_id}] failed to start: #{inspect(reason)}")
        error
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    chat_session_id = Keyword.fetch!(opts, :chat_session_id)

    %{
      id: {__MODULE__, chat_session_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5000
    }
  end

  @spec agent_id(String.t()) :: String.t()
  def agent_id(chat_session_id) when is_binary(chat_session_id) do
    @engine_session_ref_prefix <> chat_session_id
  end

  @impl true
  def on_before_cmd(agent, {Sacrum.ChatSessionRunner.Actions.RunOnce, params}) do
    instruction =
      Jido.Instruction.new!(
        action: Sacrum.ChatSessionRunner.Actions.RunOnce,
        params: params,
        opts: [timeout: 0, telemetry: :silent]
      )

    {:ok, agent, instruction}
  end

  @impl true
  def on_before_cmd(agent, action), do: {:ok, agent, action}

  @doc false
  @spec run_once(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_once(chat_session_id, opts) when is_binary(chat_session_id) and is_list(opts) do
    inference_opts = Keyword.get(opts, :inference_opts, opts)
    engine_session_ref = Keyword.get(opts, :engine_session_ref, agent_id(chat_session_id))

    result =
      with {:ok, session} <- ChatSessionsRepo.get(chat_session_id),
           {:continue, session} <- ensure_runnable(session),
           {:ok, session} <- intake(session, engine_session_ref),
           {:ok, messages} <- load_messages(session),
           {:ok, session, assistant_message} <-
             generate_or_resume_assistant(session, messages, inference_opts),
           {:ok, session} <- complete_session(session) do
        {:ok, %{session: session, assistant_message: assistant_message}}
      else
        {:halt, session, reason} ->
          {:ok, %{session: session, status: :noop, reason: reason}}

        {:error, reason} ->
          mark_failed(chat_session_id, reason)
      end

    log_result(chat_session_id, result)
    result
  end

  defp ensure_runnable(%ChatSession{} = session) do
    if ChatSessionStatus.terminal?(session.status) do
      {:halt, session, {:terminal_status, session.status}}
    else
      {:continue, session}
    end
  end

  defp intake(%ChatSession{} = session, engine_session_ref) when is_binary(engine_session_ref) do
    with {:ok, session} <- ensure_running_session(session, engine_session_ref),
         {:ok, _message} <-
           ensure_status_message(session, :intake, "Chat session started."),
         {:ok, _events} <- checkpoint_step(session, :intake, %{"status" => "running"}) do
      {:ok, session}
    end
  end

  defp load_messages(%ChatSession{} = session) do
    with {:ok, messages} <- ChatMessages.list_for_session(session, []),
         {:ok, _events} <-
           checkpoint_step(session, :load_messages, %{"message_count" => length(messages)}) do
      {:ok, messages}
    end
  end

  defp generate_or_resume_assistant(%ChatSession{} = session, messages, inference_opts) do
    case ChatMessages.get_by_client_message_id(session, @assistant_client_message_id) do
      {:ok, %ChatMessage{} = message} ->
        with {:ok, session} <- refresh_runnable_session(session),
             {:ok, _event} <- ensure_public_message_event(session, message),
             {:ok, _event} <- ensure_resumed_inference_completed_event(session, message),
             {:ok, _events} <-
               checkpoint_step(session, :append_assistant, %{
                 "assistant_message_id" => message.id,
                 "resumed" => true
               }) do
          {:ok, session, message}
        end

      {:error, :not_found} ->
        with {:ok, session, inference_result} <-
               invoke_inference(session, messages, inference_opts),
             {:ok, message} <- append_assistant_message(session, inference_result),
             {:ok, _events} <-
               checkpoint_step(session, :append_assistant, %{
                 "assistant_message_id" => message.id
               }) do
          {:ok, session, message}
        end
    end
  end

  defp invoke_inference(%ChatSession{} = session, messages, inference_opts) do
    with {:ok, result} <- Inference.generate(messages, inference_opts),
         {:ok, session} <- refresh_runnable_session(session),
         {:ok, _events} <-
           checkpoint_step(session, :invoke_inference, %{
             "provider" => Map.get(result.public_metadata, "provider"),
             "model" => Map.get(result.public_metadata, "model")
           }) do
      {:ok, session, result}
    end
  end

  defp append_assistant_message(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    attrs =
      InferenceEvents.assistant_message_attrs(inference_result,
        client_message_id: @assistant_client_message_id
      )

    with {:ok, message} <- ensure_message(session, attrs),
         {:ok, _event} <- ensure_public_message_event(session, message),
         {:ok, _event} <- append_inference_completed_event(session, message, inference_result) do
      {:ok, message}
    end
  end

  defp complete_session(%ChatSession{} = session) do
    with {:ok, session} <- refresh_runnable_session(session),
         {:ok, _message} <-
           ensure_status_message(session, :complete_session, "Chat session completed."),
         {:ok, session} <- ensure_completed_session(session),
         {:ok, _events} <- checkpoint_step(session, :complete_session, %{"status" => "completed"}) do
      {:ok, session}
    end
  end

  defp refresh_runnable_session(%ChatSession{} = session) do
    with {:ok, refreshed_session} <- ChatSessionsRepo.get(session.id),
         {:continue, refreshed_session} <- ensure_runnable(refreshed_session) do
      {:ok, refreshed_session}
    end
  end

  defp ensure_running_session(
         %ChatSession{
           status: :running,
           engine_kind: @engine_kind,
           engine_session_ref: engine_session_ref
         } = session,
         engine_session_ref
       ) do
    {:ok, session}
  end

  defp ensure_running_session(%ChatSession{status: :running} = session, engine_session_ref) do
    update_session_with_event(session, %{
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  defp ensure_running_session(%ChatSession{} = session, engine_session_ref) do
    update_session_with_event(session, %{
      status: :running,
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  defp ensure_completed_session(%ChatSession{status: :completed} = session) do
    {:ok, session}
  end

  defp ensure_completed_session(%ChatSession{} = session) do
    update_session_with_event(session, %{status: :completed})
  end

  defp update_session_with_event(%ChatSession{} = session, attrs) do
    case Repo.transaction(fn -> update_session_and_event!(session, attrs) end) do
      {:ok, {updated_session, event}} ->
        Broadcaster.broadcast_chat_event({:ok, event})
        {:ok, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  defp ensure_status_message(%ChatSession{} = session, step, content) when is_atom(step) do
    attrs = %{
      role: :status,
      content: content,
      content_format: :plain,
      client_message_id: "chat_session_runner:status:#{step}:v1",
      metadata: %{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step)
      }
    }

    with {:ok, message} <- ensure_message(session, attrs),
         {:ok, _event} <- ensure_public_message_event(session, message) do
      {:ok, message}
    end
  end

  defp ensure_message(%ChatSession{} = session, %{client_message_id: client_message_id} = attrs) do
    case ChatMessages.get_by_client_message_id(session, client_message_id) do
      {:ok, message} -> {:ok, message}
      {:error, :not_found} -> insert_idempotent_message(session, attrs, client_message_id)
    end
  end

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

  defp unique_client_message_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] == "chat_messages_chat_session_id_client_message_id_index"

      _error ->
        false
    end)
  end

  defp ensure_public_message_event(%ChatSession{} = session, %ChatMessage{} = message) do
    case ChatEvents.get_message_created_for_message(session, message.id) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        session
        |> ChatEvents.append_to_session(PublicEvents.message_created_attrs(message))
        |> broadcast_event_result()
    end
  end

  defp append_inference_completed_event(
         %ChatSession{} = session,
         %ChatMessage{} = message,
         %Inference.Result{} = inference_result
       ) do
    attrs = InferenceEvents.inference_completed_attrs(message, inference_result)

    ensure_inference_completed_event(session, attrs)
  end

  defp ensure_resumed_inference_completed_event(
         %ChatSession{} = session,
         %ChatMessage{} = message
       ) do
    attrs = InferenceEvents.resumed_inference_completed_attrs(message)

    ensure_inference_completed_event(session, attrs)
  end

  defp ensure_inference_completed_event(%ChatSession{} = session, attrs) do
    case ChatEvents.get_by_type(
           session,
           InferenceEvents.event_type(:inference_completed),
           :internal
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> ChatEvents.append_to_session(session, attrs)
    end
  end

  defp checkpoint_step(%ChatSession{} = session, step, details)
       when is_atom(step) and is_map(details) do
    event_type = "chat_session_runner.#{step}.completed"
    public_payload = runner_public_payload(session, step, details)

    internal_payload =
      Inference.scrub_secrets(%{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step),
        "details" => details
      })

    with {:ok, public_event} <-
           ensure_event(session, event_type, :public, public_payload, %{}),
         {:ok, internal_event} <-
           ensure_event(session, event_type, :internal, %{}, internal_payload) do
      {:ok, [public_event, internal_event]}
    end
  end

  defp runner_public_payload(%ChatSession{} = session, step, details) do
    details
    |> Map.take([
      "status",
      "message_count",
      "assistant_message_id",
      "resumed",
      "provider",
      "model"
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(%{
      "chat_session_id" => session.id,
      "step" => Atom.to_string(step)
    })
  end

  defp ensure_event(
         %ChatSession{} = session,
         event_type,
         visibility,
         public_payload,
         internal_payload
       ) do
    case ChatEvents.get_by_type(session, event_type, visibility) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        attrs = %{
          event_type: event_type,
          visibility: visibility,
          public_payload: public_payload,
          internal_payload: internal_payload
        }

        session
        |> ChatEvents.append_to_session(attrs)
        |> broadcast_event_result()
    end
  end

  defp broadcast_event_result({:ok, event} = result) do
    Broadcaster.broadcast_chat_event(result)
    {:ok, event}
  end

  defp broadcast_event_result(error), do: error

  defp mark_failed(chat_session_id, reason) do
    case ChatSessionsRepo.get(chat_session_id) do
      {:ok, %ChatSession{} = session} ->
        failed_reason = inspect(reason)

        with {:continue, session} <- ensure_runnable(session),
             {:ok, failed_session} <- update_session_with_event(session, %{status: :failed}),
             {:ok, _events} <-
               checkpoint_step(failed_session, :failed, %{"reason" => failed_reason}) do
          {:error, reason}
        else
          {:halt, _session, _reason} -> {:error, reason}
          {:error, _failure_reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, reason}
    end
  end

  defp run_signal(chat_session_id, engine_session_ref, inference_opts) do
    Jido.Signal.new!(
      @run_signal_type,
      %{
        chat_session_id: chat_session_id,
        engine_session_ref: engine_session_ref,
        inference_opts: inference_opts
      },
      source: "/sacrum/chat_session_runner"
    )
  end

  defp start_completion_cleanup(pid) when is_pid(pid) do
    Task.start(fn -> await_completion_and_stop(pid) end)
    :ok
  end

  defp await_completion_and_stop(pid) do
    case Jido.AgentServer.await_completion(pid, timeout: :infinity) do
      {:ok, _completion} ->
        Process.sleep(@completion_cleanup_delay_ms)
        stop_agent_server(pid)

      {:error, _reason} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp stop_agent_server(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp log_result(chat_session_id, {:ok, %{status: :noop, reason: reason}}) do
    Logger.info("[ChatSessionRunner:#{chat_session_id}] no-op: #{inspect(reason)}")
  end

  defp log_result(chat_session_id, {:ok, _result}) do
    Logger.info("[ChatSessionRunner:#{chat_session_id}] completed")
  end

  defp log_result(chat_session_id, {:error, reason}) do
    Logger.error("[ChatSessionRunner:#{chat_session_id}] failed: #{inspect(reason)}")
  end
end
