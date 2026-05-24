defmodule Sacrum.Chat.Inference.OpenRouter do
  @moduledoc """
  OpenRouter-backed chat inference provider.

  This module validates Sacrum runtime configuration, then delegates inference
  orchestration to a Jido action. OpenRouter credentials stay in process memory
  and are never included in normalized results.
  """

  @behaviour Sacrum.Chat.Inference.Provider

  require Logger

  alias Sacrum.Chat.{AuthoringTools, DirectTrackerOperationTools}
  alias Sacrum.Chat.Inference
  alias Sacrum.Chat.Inference.Actions.OpenRouterChat
  alias Sacrum.Chat.Inference.Result

  @default_base_url "https://openrouter.ai/api/v1"
  @default_tool_choice "auto"
  @tool_only_assistant_placeholder "(starting Vertebrae authoring draft…)"

  @impl true
  def generate(messages, opts \\ []) when is_list(messages) do
    config = openrouter_config(opts)

    with :ok <- validate_config(config),
         {:ok, action_result} <- run_jido_action(messages, config, opts) do
      source_message_id = source_message_id_from(opts, messages)
      {:ok, normalize_action_result(action_result, config, source_message_id)}
    end
  end

  defp source_message_id_from(opts, messages) do
    case Keyword.get(opts, :source_message_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        messages
        |> Enum.reverse()
        |> Enum.find(&user_message?/1)
        |> message_id()
    end
  end

  defp user_message?(message),
    do: Map.get(message, :role) == "user" or Map.get(message, "role") == "user"

  defp message_id(%{} = msg), do: Map.get(msg, :id) || Map.get(msg, "id")
  defp message_id(_), do: nil

  @spec configured?(keyword()) :: boolean()
  def configured?(opts \\ []) do
    opts
    |> openrouter_config()
    |> missing_config_fields()
    |> Enum.empty?()
  end

  defp run_jido_action(messages, config, opts) do
    timeout = Keyword.get(opts, :timeout, config.timeout)
    tools = Keyword.get(opts, :tools)
    tool_choice = Keyword.get(opts, :tool_choice, @default_tool_choice)
    response_format = Keyword.get(opts, :response_format)

    params =
      %{
        messages: messages,
        model: config.model,
        base_url: config.base_url,
        api_key: config.api_key
      }
      |> maybe_put(:app_referer, config.app_referer)
      |> maybe_put(:app_title, config.app_title)
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:max_tokens, Keyword.get(opts, :max_tokens))
      |> maybe_put(
        :reasoning_effort,
        Keyword.get(opts, :reasoning_effort, config.reasoning_effort)
      )
      |> maybe_put(:provider_options, Keyword.get(opts, :provider_options))
      |> maybe_put(:timeout, timeout)
      |> maybe_put(:tools, tools)
      |> maybe_put_tool_choice(tool_choice, tools)
      |> maybe_put(:response_format, response_format)

    case Jido.Exec.run(OpenRouterChat, params, %{}, timeout: timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:openrouter_request_failed, scrub_error(reason, config)}}
    end
  end

  defp maybe_put_tool_choice(map, _tool_choice, nil), do: map
  defp maybe_put_tool_choice(map, _tool_choice, []), do: map

  defp maybe_put_tool_choice(map, tool_choice, _tools),
    do: Map.put(map, :tool_choice, tool_choice)

  @doc false
  @spec normalize_action_result(map(), map(), String.t() | nil) :: Result.t()
  def normalize_action_result(result, config, source_message_id) do
    model = fetch_result(result, :model) || config.model

    metadata = action_metadata(result, model, source_message_id)
    content = content_for_result(fetch_result(result, :text), metadata.internal)

    %Result{
      content: content,
      content_format: :markdown,
      public_metadata: metadata.public,
      internal_metadata: metadata.internal
    }
  end

  defp content_for_result(text, internal_metadata) do
    cond do
      is_binary(text) and String.trim(text) != "" ->
        text

      has_tool_directive?(internal_metadata) ->
        @tool_only_assistant_placeholder

      true ->
        text
    end
  end

  defp action_metadata(result, model, source_message_id) do
    usage = normalized_usage(fetch_result(result, :usage) || %{})
    finish_reason = normalize_value(fetch_result(result, :finish_reason))

    %{
      public: public_metadata(model, usage, finish_reason),
      internal: internal_metadata(result, model, usage, finish_reason, source_message_id)
    }
  end

  defp public_metadata(model, usage, finish_reason) do
    metadata = %{
      "provider" => "openrouter",
      "model" => model,
      "usage" => public_usage(usage)
    }

    maybe_put_string(metadata, "finish_reason", finish_reason)
  end

  defp internal_metadata(result, model, usage, finish_reason, source_message_id) do
    provider_metadata = fetch_result(result, :provider_metadata) || %{}

    %{
      "provider" => "openrouter",
      "model" => model,
      "usage" => usage,
      "provider_metadata" => normalize_value(provider_metadata)
    }
    |> maybe_put_string("reasoning", reasoning_metadata(result))
    |> maybe_put_string("finish_reason", finish_reason)
    |> maybe_put_tool_directive(result, source_message_id)
  end

  defp has_tool_directive?(metadata) do
    Map.has_key?(metadata, "authoring_tool_intent") or
      Map.has_key?(metadata, "direct_tracker_operation")
  end

  defp maybe_put_tool_directive(metadata, result, source_message_id) do
    case extract_tool_directive(result, source_message_id) do
      nil ->
        metadata

      {:direct_tracker_operation, operation} ->
        Map.put(metadata, "direct_tracker_operation", operation)

      {:authoring_tool_intent, intent} ->
        Map.put(metadata, "authoring_tool_intent", intent)
    end
  end

  defp extract_tool_directive(result, source_message_id) do
    case fetch_result(result, :tool_calls) do
      [_ | _] = list ->
        pick_tool_directive(list, source_message_id)

      _ ->
        nil
    end
  end

  defp pick_tool_directive(list, source_message_id) do
    list
    |> Enum.flat_map(&List.wrap(parse_tool_call(&1, source_message_id)))
    |> case do
      [] -> nil
      [directive] -> directive
      [directive | extras] -> log_extra_tool_directives_and_keep(directive, extras)
    end
  end

  defp log_extra_tool_directives_and_keep({key, payload}, extras) do
    labels =
      Enum.map([{key, payload} | extras], fn {directive_key, _payload} -> directive_key end)

    if Enum.all?(labels, &(&1 == key)) do
      {key,
       log_extra_tool_calls_and_keep(payload, Enum.map(extras, &elem(&1, 1)), label_for(key))}
    else
      Logger.warning(fn ->
        "[chat.inference.open_router] received #{length(extras) + 1} mixed tool_calls " <>
          "in one response; keeping the first and dropping the rest"
      end)

      {key, payload}
    end
  end

  defp log_extra_tool_calls_and_keep(payload, extras, label) do
    Logger.warning(fn ->
      "[chat.inference.open_router] received #{length(extras) + 1} #{label} tool_calls " <>
        "in one response; keeping the first and dropping the rest"
    end)

    payload
  end

  defp label_for(:authoring_tool_intent), do: "authoring"
  defp label_for(:direct_tracker_operation), do: "direct tracker"

  defp parse_tool_call(tool_call, source_message_id) do
    case tool_call_name(tool_call) do
      nil -> nil
      name -> directive_for_known_name(name, tool_call, source_message_id)
    end
  end

  defp directive_for_known_name(name, tool_call, source_message_id) do
    cond do
      AuthoringTools.known_function_name?(name) ->
        {:authoring_tool_intent,
         build_intent(name, tool_call_arguments(tool_call), source_message_id)}

      DirectTrackerOperationTools.known_function_name?(name) ->
        {:direct_tracker_operation,
         build_direct_operation(name, tool_call_arguments(tool_call), source_message_id)}

      true ->
        log_unknown_tool_call(name)
        nil
    end
  end

  defp build_direct_operation(name, arguments, source_message_id) do
    operation = %{
      "action" => name,
      "arguments" => DirectTrackerOperationTools.sanitize_arguments(arguments)
    }

    maybe_put_string(operation, "source_message_id", source_message_id)
  end

  defp log_unknown_tool_call(name) do
    Logger.warning(fn ->
      "[chat.inference.open_router] dropping tool_call for unknown function " <> inspect(name)
    end)
  end

  defp build_intent(name, arguments, source_message_id) do
    intent =
      arguments
      |> Map.put("action", name)
      |> maybe_put_string("source_message_id", source_message_id)

    Logger.debug(fn ->
      keys = intent |> Map.keys() |> Enum.sort()
      "[chat.inference.open_router] parsed tool_call name=#{name} arg_keys=#{inspect(keys)}"
    end)

    intent
  end

  defp tool_call_name(%{"function" => %{"name" => name}}), do: name
  defp tool_call_name(%{function: %{name: name}}), do: name
  defp tool_call_name(%{"name" => name}), do: name
  defp tool_call_name(%{name: name}), do: name
  defp tool_call_name(_), do: nil

  defp tool_call_arguments(%{"function" => %{"arguments" => args}}), do: decode_arguments(args)
  defp tool_call_arguments(%{function: %{arguments: args}}), do: decode_arguments(args)
  defp tool_call_arguments(%{"arguments" => args}), do: decode_arguments(args)
  defp tool_call_arguments(%{arguments: args}), do: decode_arguments(args)
  defp tool_call_arguments(_), do: %{}

  defp decode_arguments(args) when is_map(args) and not is_struct(args), do: normalize_value(args)

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_arguments(_), do: %{}

  defp fetch_result(result, key) when is_atom(key) do
    Map.get(result, key) || Map.get(result, Atom.to_string(key))
  end

  defp openrouter_config(opts) do
    explicit_config = normalize_config(Keyword.get(opts, :config, []))

    app_config =
      :sacrum
      |> Application.get_env(:chat_inference, [])
      |> Keyword.get(:openrouter, [])

    merged_config = Keyword.merge(app_config, explicit_config)

    %{
      api_key: blank_to_nil(Keyword.get(merged_config, :api_key)),
      base_url: blank_to_nil(Keyword.get(merged_config, :base_url, @default_base_url)),
      model: blank_to_nil(Keyword.get(merged_config, :model)),
      app_referer: blank_to_nil(Keyword.get(merged_config, :app_referer)),
      app_title: blank_to_nil(Keyword.get(merged_config, :app_title)),
      reasoning_effort: blank_to_nil(Keyword.get(merged_config, :reasoning_effort)),
      timeout: Inference.timeout(timeout: Keyword.get(merged_config, :timeout))
    }
  end

  defp validate_config(config) do
    case missing_config_fields(config) do
      [] -> :ok
      missing -> {:error, {:missing_openrouter_config, missing}}
    end
  end

  defp missing_config_fields(config) do
    Enum.reject([:api_key, :base_url, :model], fn field ->
      present?(Map.fetch!(config, field))
    end)
  end

  defp present?(value), do: not is_nil(blank_to_nil(value))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp reasoning_metadata(result) do
    reasoning_text = fetch_result(result, :reasoning_text)
    reasoning_details = fetch_result(result, :reasoning_details) || []
    reasoning_tokens = fetch_result(result, :reasoning_tokens)

    normalized_details = normalize_value(reasoning_details || [])
    normalized_text = blank_to_nil(reasoning_text)
    normalized_tokens = reasoning_tokens || 0

    if is_nil(normalized_text) and normalized_details == [] and normalized_tokens == 0 do
      nil
    else
      %{
        "text" => normalized_text,
        "details" => normalized_details,
        "tokens" => normalized_tokens
      }
    end
  end

  defp normalized_usage(usage), do: normalize_value(usage || %{})

  defp public_usage(usage) when is_map(usage) do
    usage
    |> Map.drop(["reasoning", "reasoning_tokens", "thinking_tokens"])
    |> drop_nested_usage_keys("completion_tokens_details", [
      "reasoning",
      "reasoning_tokens",
      "thinking_tokens"
    ])
    |> drop_nested_usage_keys("output_tokens_details", [
      "reasoning",
      "reasoning_tokens",
      "thinking_tokens"
    ])
  end

  defp public_usage(usage), do: usage

  defp drop_nested_usage_keys(usage, key, nested_keys) do
    case Map.get(usage, key) do
      nested when is_map(nested) -> Map.put(usage, key, Map.drop(nested, nested_keys))
      _other -> usage
    end
  end

  defp normalize_value(%ReqLLM.Message.ReasoningDetails{} = detail) do
    detail
    |> Map.from_struct()
    |> normalize_value()
  end

  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_value(nested_value)} end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_config(config) when is_map(config), do: Map.to_list(config)
  defp normalize_config(config) when is_list(config), do: config
  defp normalize_config(_config), do: []

  defp scrub_error(reason, %{api_key: secret}) when is_binary(secret) and secret != "" do
    reason
    |> inspect()
    |> String.replace(secret, "[REDACTED]")
  end

  defp scrub_error(reason, _config), do: inspect(reason)
end
