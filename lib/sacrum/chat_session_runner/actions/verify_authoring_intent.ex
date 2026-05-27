defmodule Sacrum.ChatSessionRunner.Actions.VerifyAuthoringIntent do
  @moduledoc """
  Verifier gate that sits between InvokeInference and AppendAssistant.

  When the inference result carries no `authoring_tool_intent` the action is a
  pass-through that emits `append_assistant` unchanged.

  When an intent is present:

    1. Rule-based schema checks run first (known function, required keys,
       known run kind / state_machine_id, etc.). On hard schema failure the
       intent is stripped, the assistant message is rewritten to ask the
       user to clarify, and `append_assistant` is emitted without an intent.

    2. If schema checks pass and the verifier is enabled (config flag
       `:sacrum, :authoring_verifier, enabled: false` initially), an LLM
       verifier call runs. On `sufficient: true` the intent flows through
       unchanged. On `sufficient: false` the intent is stripped and the
       assistant content is rewritten to ask the verifier's open questions.
       On verifier error, the intent is treated as rejected (fail-closed).

    3. When the verifier is disabled, schema-pass intents flow through
       unchanged so the producer side can ship without blocking on the
       verifier rollout.

  The verifier must never produce a new intent — it can only accept or strip
  the existing one.
  """

  use Jido.Action,
    name: "sacrum_chat_session_verify_authoring_intent",
    description: "Verify the authoring tool intent emitted by inference",
    category: "chat",
    tags: ["sacrum", "chat", "session", "verify_authoring"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []],
      turn_message_id: [type: :string],
      inference_result: [type: :any, required: true]
    ]

  require Logger

  alias Sacrum.Accounts.{AuthoringDrafts, AuthoringRunKinds}

  alias Sacrum.Chat.{
    AuthoringTools,
    AuthoringVerifierPrompt,
    DirectTrackerOperationResolver,
    Inference
  }

  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.DirectTracker.Continuation, as: DirectTrackerContinuation
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.Repo.Schemas.{Artifact, ChatSession}

  @impl true
  def run(params, _context) do
    with :ok <- validate_result(params.inference_result),
         {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, next_result} <- verify(session, params.inference_result),
         {:ok, directive} <- route_verified_result(session, next_result, params) do
      {:ok, %{step: :verify_authoring, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  @doc false
  @spec verify(ChatSession.t(), Result.t()) :: {:ok, Result.t()} | {:error, term()}
  def verify(%ChatSession{} = session, %Result{} = result) do
    with {:ok, result} <- verify_authoring_intent(session, result) do
      verify_direct_tracker_operation(session, result)
    end
  end

  defp route_verified_result(%ChatSession{} = session, %Result{} = result, params) do
    metadata = result.internal_metadata
    turn_message_id = Map.get(params, :turn_message_id)

    cond do
      direct_tracker_operations_resolved?(metadata) ->
        with {:ok, session, continued_result} <-
               Pipeline.continue_after_direct_tracker_operation(
                 session,
                 result,
                 params.inference_opts,
                 turn_message_id
               ) do
          {:ok, append_assistant_directive(session, continued_result, params)}
        end

      is_map(Map.get(metadata, "direct_tracker_operation_rejected")) ->
        with {:ok, _event} <-
               Pipeline.record_direct_tracker_operation_rejection(
                 session,
                 result,
                 turn_message_id
               ) do
          {:ok, complete_session_directive(session, params)}
        end

      true ->
        {:ok, append_assistant_directive(session, result, params)}
    end
  end

  defp append_assistant_directive(%ChatSession{} = session, %Result{} = result, params) do
    Actions.emit(Signals.append_assistant(), %{
      chat_session_id: session.id,
      engine_session_ref: params.engine_session_ref,
      inference_opts: params.inference_opts,
      turn_message_id: Map.get(params, :turn_message_id),
      inference_result: result
    })
  end

  defp complete_session_directive(%ChatSession{} = session, params) do
    Actions.emit(Signals.complete_session(), %{
      chat_session_id: session.id,
      engine_session_ref: params.engine_session_ref,
      inference_opts: params.inference_opts,
      turn_message_id: Map.get(params, :turn_message_id)
    })
  end

  defp verify_authoring_intent(%ChatSession{} = session, %Result{} = result) do
    case get_in(result.internal_metadata, ["authoring_tool_intent"]) do
      nil ->
        {:ok, result}

      %{} = intent ->
        case rule_check(intent) do
          :ok -> maybe_run_verifier(session, result, intent)
          {:error, reason} -> {:ok, reject_with_schema_error(result, reason)}
        end

      _other ->
        {:ok, reject_with_schema_error(result, :invalid_authoring_tool_intent)}
    end
  end

  defp verify_direct_tracker_operation(%ChatSession{} = session, %Result{} = result) do
    metadata = result.internal_metadata || %{}

    case {Map.get(metadata, "direct_tracker_operations"),
          Map.get(metadata, "direct_tracker_operation")} do
      {nil, nil} ->
        {:ok, result}

      {nil, %{} = directive} ->
        context = DirectTrackerOperationResolver.context_from_session(session)

        case DirectTrackerOperationResolver.resolve_directive(directive, context) do
          {:ok, resolved} -> {:ok, put_resolved_direct_tracker_operation(result, resolved)}
          {:error, reason} -> {:ok, reject_direct_tracker_operation(result, reason)}
        end

      {directives, nil} when is_list(directives) ->
        verify_direct_tracker_operations(session, result, directives)

      _other ->
        {:ok, reject_direct_tracker_operation(result, :invalid_direct_tracker_operation)}
    end
  end

  defp verify_direct_tracker_operations(%ChatSession{} = session, %Result{} = result, directives) do
    context = DirectTrackerOperationResolver.context_from_session(session)

    with :ok <- validate_compound_direct_tracker_directives(directives),
         {:ok, resolved} <- DirectTrackerOperationResolver.resolve_directives(directives, context),
         :ok <- validate_compound_direct_tracker_operations(resolved) do
      {:ok, put_resolved_direct_tracker_operations(result, resolved)}
    else
      {:error, reason} -> {:ok, reject_direct_tracker_operation(result, reason)}
    end
  end

  defp direct_tracker_operations_resolved?(metadata) when is_map(metadata) do
    is_map(Map.get(metadata, "resolved_direct_tracker_operation")) or
      is_list(Map.get(metadata, "resolved_direct_tracker_operations"))
  end

  defp validate_compound_direct_tracker_directives([
         %{} = show_task,
         %{} = upsert_task_section
       ]) do
    case {directive_action(show_task), directive_action(upsert_task_section)} do
      {"show_task", "upsert_task_section"} ->
        :ok

      _other ->
        {:error, :unsupported_compound_direct_tracker_operations}
    end
  end

  defp validate_compound_direct_tracker_directives(_directives),
    do: {:error, :unsupported_compound_direct_tracker_operations}

  defp directive_action(directive),
    do: Map.get(directive, "action") || Map.get(directive, :action)

  defp validate_compound_direct_tracker_operations([
         %{action: "show_task", targets: %{task: task}},
         %{action: "upsert_task_section", targets: %{task: task}}
       ]),
       do: :ok

  defp validate_compound_direct_tracker_operations(_operations),
    do: {:error, :unsupported_compound_direct_tracker_operations}

  @doc """
  Pure rule-based schema check over an authoring intent.
  """
  @spec rule_check(map()) :: :ok | {:error, term()}
  def rule_check(%{} = intent) do
    with {:ok, action} <- fetch_string(intent, "action"),
         :ok <- ensure_known_function(action),
         {:ok, required} <- required_keys(action),
         :ok <- ensure_required_keys(intent, required),
         :ok <- ensure_run_kind_consistency(action, intent) do
      ensure_state_machine_id_known(action, intent)
    end
  end

  def rule_check(_), do: {:error, :invalid_authoring_tool_intent}

  defp ensure_known_function(action) do
    if AuthoringTools.known_function_name?(action) do
      :ok
    else
      {:error, {:unknown_authoring_function, action}}
    end
  end

  defp required_keys(action) do
    case AuthoringTools.required_keys(action) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, {:unknown_authoring_function, action}}
    end
  end

  defp ensure_required_keys(intent, keys) do
    missing = Enum.reject(keys, &present_string?(Map.get(intent, &1)))

    if missing == [] do
      :ok
    else
      {:error, {:missing_intent_fields, missing}}
    end
  end

  defp present_string?(value) when is_binary(value) and value != "", do: true
  defp present_string?(_), do: false

  defp ensure_run_kind_consistency("start_authoring", intent) do
    run_kind = Map.get(intent, "run_kind")

    case AuthoringRunKinds.fetch(run_kind) do
      {:ok, descriptor} ->
        cond do
          Map.get(intent, "artifact_type") not in [nil, descriptor.artifact_type] ->
            {:error, {:run_kind_mismatch, :artifact_type}}

          Map.get(intent, "template_kind") not in [nil, descriptor.template_kind] ->
            {:error, {:run_kind_mismatch, :template_kind}}

          Map.get(intent, "state_machine_entrypoint") not in [
            nil,
            descriptor.state_machine_entrypoint
          ] ->
            {:error, {:run_kind_mismatch, :state_machine_entrypoint}}

          Map.get(intent, "state_machine_id") not in [nil, descriptor.state_machine_id] ->
            {:error, {:run_kind_mismatch, :state_machine_id}}

          Map.get(intent, "initial_state") not in [nil, descriptor.initial_state] ->
            {:error, {:run_kind_mismatch, :initial_state}}

          true ->
            :ok
        end

      {:error, :not_found} ->
        {:error, {:unknown_run_kind, run_kind}}
    end
  end

  defp ensure_run_kind_consistency(_action, _intent), do: :ok

  defp ensure_state_machine_id_known("revise_authoring", intent) do
    state_machine_id = Map.get(intent, "state_machine_id")

    if state_machine_id in AuthoringRunKinds.state_machine_ids() do
      :ok
    else
      {:error, {:unknown_state_machine_id, state_machine_id}}
    end
  end

  defp ensure_state_machine_id_known(_action, _intent), do: :ok

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_intent_field, key}}
    end
  end

  defp maybe_run_verifier(%ChatSession{} = session, %Result{} = result, intent) do
    if verifier_enabled?(), do: run_verifier(session, result, intent), else: {:ok, result}
  end

  defp verifier_enabled? do
    :sacrum
    |> Application.get_env(:authoring_verifier, [])
    |> Keyword.get(:enabled, false)
  end

  defp run_verifier(%ChatSession{} = session, %Result{} = result, intent) do
    case call_verifier(session, intent) do
      {:ok, %{"sufficient" => true}} ->
        {:ok, result}

      {:ok, %{"sufficient" => false} = verdict} ->
        {:ok, reject_with_verifier_verdict(result, verdict)}

      {:ok, _other} ->
        Logger.warning(fn ->
          "[verify_authoring_intent] verifier returned malformed verdict; rejecting fail-closed"
        end)

        {:ok, reject_with_verifier_error(result, :malformed_verifier_verdict)}

      {:error, reason} ->
        Logger.warning(fn ->
          "[verify_authoring_intent] verifier call failed: #{inspect(reason)}; " <>
            "rejecting fail-closed"
        end)

        {:ok, reject_with_verifier_error(result, reason)}
    end
  end

  defp call_verifier(%ChatSession{} = session, intent) do
    verifier_config = Application.get_env(:sacrum, :authoring_verifier, [])
    transcript = load_transcript(verifier_config, session)
    active_draft = active_draft_for(session, intent)
    system_prompt = AuthoringVerifierPrompt.build(transcript, intent, active_draft)

    opts =
      verifier_config
      |> Keyword.get(:opts, [])
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:response_format, AuthoringVerifierPrompt.response_format())
      |> Keyword.put_new(:provider, Keyword.get(verifier_config, :provider))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, %Result{} = verifier_result} <- Inference.generate(transcript, opts) do
      case Jason.decode(verifier_result.content) do
        {:ok, %{} = verdict} -> {:ok, verdict}
        _ -> {:error, :unparseable_verifier_content}
      end
    end
  end

  defp load_transcript(verifier_config, session) do
    case Keyword.get(verifier_config, :transcript_loader) do
      loader when is_function(loader, 1) -> loader.(session)
      _ -> []
    end
  end

  defp active_draft_for(%ChatSession{} = session, intent) do
    state_machine_id = Map.get(intent, "state_machine_id")

    if is_binary(state_machine_id) do
      case AuthoringDrafts.get_for_chat_session(session, state_machine_id) do
        {:ok, %{artifact: %Artifact{} = artifact}} -> artifact
        _ -> nil
      end
    end
  end

  defp reject_with_schema_error(%Result{} = result, reason) do
    Logger.warning(fn ->
      "[verify_authoring_intent] rule-based reject: #{inspect(reason)}"
    end)

    metadata = Map.delete(result.internal_metadata || %{}, "authoring_tool_intent")

    %Result{
      result
      | content: schema_error_followup(),
        internal_metadata:
          Map.put(metadata, "authoring_tool_intent_rejected", %{
            "reason" => "schema_check_failed",
            "details" => inspect(reason)
          })
    }
  end

  defp reject_with_verifier_verdict(%Result{} = result, verdict) do
    open_questions =
      case Map.get(verdict, "open_questions") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    missing =
      case Map.get(verdict, "missing") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    content = verifier_followup(open_questions)
    metadata = Map.delete(result.internal_metadata || %{}, "authoring_tool_intent")

    %Result{
      result
      | content: content,
        internal_metadata:
          Map.put(metadata, "authoring_tool_intent_rejected", %{
            "reason" => "verifier_insufficient",
            "open_questions" => open_questions,
            "missing" => missing
          })
    }
  end

  defp reject_with_verifier_error(%Result{} = result, reason) do
    metadata = Map.delete(result.internal_metadata || %{}, "authoring_tool_intent")

    %Result{
      result
      | content: verifier_error_followup(),
        internal_metadata:
          Map.put(metadata, "authoring_tool_intent_rejected", %{
            "reason" => "verifier_error",
            "details" => inspect(reason)
          })
    }
  end

  defp schema_error_followup do
    "I started to draft a Vertebrae authoring intent but the arguments did not " <>
      "match the expected shape. Could you clarify the run kind and the desired " <>
      "state machine before we continue?"
  end

  defp verifier_followup([]) do
    "I considered starting a Vertebrae authoring draft but the context still " <>
      "feels thin. Could you share more about the scope and the outcome you want?"
  end

  defp verifier_followup(open_questions) do
    questions = Enum.map_join(open_questions, "\n", &"- #{&1}")
    "Before I draft anything in Vertebrae, can you answer the following?\n\n" <> questions
  end

  defp verifier_error_followup do
    "I wanted to draft a Vertebrae authoring intent but could not verify it just " <>
      "now. Could you restate what you want me to draft so we can try again?"
  end

  defp put_resolved_direct_tracker_operation(%Result{} = result, resolved) do
    metadata =
      (result.internal_metadata || %{})
      |> Map.delete("direct_tracker_operation")
      |> Map.put(
        "resolved_direct_tracker_operation",
        DirectTrackerOperationResolver.serialize_resolution(resolved)
      )
      |> DirectTrackerContinuation.put_metadata([resolved])

    %Result{result | internal_metadata: metadata}
  end

  defp put_resolved_direct_tracker_operations(%Result{} = result, resolved) do
    metadata =
      (result.internal_metadata || %{})
      |> Map.delete("direct_tracker_operations")
      |> Map.put(
        "resolved_direct_tracker_operations",
        DirectTrackerOperationResolver.serialize_resolutions(resolved)
      )
      |> DirectTrackerContinuation.put_metadata(resolved)

    %Result{result | internal_metadata: metadata}
  end

  defp reject_direct_tracker_operation(%Result{} = result, reason) do
    Logger.warning(fn ->
      "[verify_authoring_intent] direct tracker operation rejected: #{inspect(reason)}"
    end)

    metadata =
      (result.internal_metadata || %{})
      |> Map.delete("direct_tracker_operation")
      |> Map.delete("direct_tracker_operations")

    %Result{
      result
      | internal_metadata:
          Map.put(metadata, "direct_tracker_operation_rejected", %{
            "reason" => "resolution_failed",
            "reason_code" => direct_tracker_rejection_reason_code(reason),
            "details" => inspect(reason)
          })
    }
  end

  defp direct_tracker_rejection_reason_code({:forbidden_model_scope_fields, _fields}),
    do: "out_of_scope"

  defp direct_tracker_rejection_reason_code({:ambiguous, _candidates}),
    do: "ambiguous_target"

  defp direct_tracker_rejection_reason_code(_reason), do: "out_of_scope"

  @spec validate_result(term()) :: :ok | {:error, :invalid_inference_result_payload}
  defp validate_result(%Result{}), do: :ok
  defp validate_result(_other), do: {:error, :invalid_inference_result_payload}
end
