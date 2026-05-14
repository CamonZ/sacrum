defmodule Sacrum.Chat.Inference.OpenRouter do
  @moduledoc """
  OpenRouter-backed chat inference provider.

  This module validates Sacrum runtime configuration, then delegates inference
  orchestration to a Jido action. OpenRouter credentials stay in process memory
  and are never included in normalized results.
  """

  @behaviour Sacrum.Chat.Inference.Provider

  alias Sacrum.Chat.Inference
  alias Sacrum.Chat.Inference.Actions.OpenRouterChat
  alias Sacrum.Chat.Inference.Result

  @default_base_url "https://openrouter.ai/api/v1"

  @impl true
  def generate(messages, opts \\ []) when is_list(messages) do
    config = openrouter_config(opts)

    with :ok <- validate_config(config),
         {:ok, action_result} <- run_jido_action(messages, config, opts) do
      {:ok, normalize_action_result(action_result, config)}
    end
  end

  @spec configured?(keyword()) :: boolean()
  def configured?(opts \\ []) do
    opts
    |> openrouter_config()
    |> missing_config_fields()
    |> Enum.empty?()
  end

  defp run_jido_action(messages, config, opts) do
    timeout = Keyword.get(opts, :timeout, config.timeout)

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

    case Jido.Exec.run(OpenRouterChat, params, %{}, timeout: timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:openrouter_request_failed, scrub_error(reason, config)}}
    end
  end

  defp normalize_action_result(result, config) do
    model = fetch_result(result, :model) || config.model

    metadata = action_metadata(result, model)

    %Result{
      content: fetch_result(result, :text),
      content_format: :markdown,
      public_metadata: metadata.public,
      internal_metadata: metadata.internal
    }
  end

  defp action_metadata(result, model) do
    usage = normalized_usage(fetch_result(result, :usage) || %{})
    finish_reason = normalize_value(fetch_result(result, :finish_reason))

    %{
      public: public_metadata(model, usage, finish_reason),
      internal: internal_metadata(result, model, usage, finish_reason)
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

  defp internal_metadata(result, model, usage, finish_reason) do
    provider_metadata = fetch_result(result, :provider_metadata) || %{}

    %{
      "provider" => "openrouter",
      "model" => model,
      "usage" => usage,
      "provider_metadata" => normalize_value(provider_metadata)
    }
    |> maybe_put_string("reasoning", reasoning_metadata(result))
    |> maybe_put_string("finish_reason", finish_reason)
  end

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
