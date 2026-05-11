defmodule Sacrum.ChatSessionRunner do
  @moduledoc """
  Jido AgentServer-backed runtime for one persisted chat session assistant turn.

  Each durable step (intake, load messages, invoke inference, append assistant,
  resume assistant, complete session) is a distinct Jido action under
  `Sacrum.ChatSessionRunner.Actions.*`. Actions consume validated signal
  payloads and emit the next signal as a `Jido.Agent.Directive.Emit` directive,
  so the AgentServer is the single coordination boundary — Sacrum is not
  wrapping Jido in a second ad hoc runner abstraction.

  Sacrum still owns durable state: `ChatSession`, `ChatMessage`, `ChatEvent`,
  and the `engine_session_ref` mapping live in Postgres. The Jido agent
  carries only the run identifiers in its ephemeral state so its terminal
  status flips to `:completed` or `:failed` and `Jido.AgentServer.await_completion/2`
  can unblock supervisors and tests.
  """

  alias Sacrum.ChatSessionRunner.Signals

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
      {Signals.run(), Sacrum.ChatSessionRunner.Actions.Intake},
      {Signals.intake(), Sacrum.ChatSessionRunner.Actions.Intake},
      {Signals.load_messages(), Sacrum.ChatSessionRunner.Actions.LoadMessages},
      {Signals.invoke_inference(), Sacrum.ChatSessionRunner.Actions.InvokeInference},
      {Signals.append_assistant(), Sacrum.ChatSessionRunner.Actions.AppendAssistant},
      {Signals.resume_assistant(), Sacrum.ChatSessionRunner.Actions.ResumeAssistant},
      {Signals.complete_session(), Sacrum.ChatSessionRunner.Actions.CompleteSession},
      {Signals.mark_failed(), Sacrum.ChatSessionRunner.Actions.MarkFailed}
    ]

  require Logger

  alias Sacrum.ChatSessionRunner.Actions

  @engine_session_ref_prefix "jido_agent_server:"
  @completion_cleanup_delay_ms 100

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
             Actions.run_signal(chat_session_id, engine_session_ref, inference_opts)
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

  @spec start_completion_cleanup(pid()) :: :ok
  defp start_completion_cleanup(pid) when is_pid(pid) do
    Task.start(fn -> await_completion_and_stop(pid) end)
    :ok
  end

  @spec await_completion_and_stop(pid()) :: :ok
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

  @spec stop_agent_server(pid()) :: :ok
  defp stop_agent_server(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
