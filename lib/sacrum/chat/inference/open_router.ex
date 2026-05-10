defmodule Sacrum.Chat.Inference.OpenRouter do
  @moduledoc """
  OpenRouter-backed chat inference provider.

  This module validates Sacrum runtime configuration, then delegates inference
  orchestration to a Jido action. OpenRouter credentials stay in process memory
  and are never included in normalized results.
  """

  @behaviour Sacrum.Chat.Inference.Provider

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
      |> maybe_put(:timeout, Keyword.get(opts, :timeout))

    case Jido.Exec.run(Sacrum.Chat.Inference.Actions.OpenRouterChat, params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:openrouter_request_failed, scrub_error(reason, config)}}
    end
  end

  defp normalize_action_result(result, config) do
    usage = normalized_usage(Map.get(result, :usage) || Map.get(result, "usage") || %{})
    model = Map.get(result, :model) || Map.get(result, "model") || config.model
    finish_reason = Map.get(result, :finish_reason) || Map.get(result, "finish_reason")

    provider_metadata =
      Map.get(result, :provider_metadata) || Map.get(result, "provider_metadata") || %{}

    public_metadata =
      maybe_put_string(
        %{
          "provider" => "openrouter",
          "model" => model,
          "usage" => usage
        },
        "finish_reason",
        normalize_value(finish_reason)
      )

    internal_metadata =
      maybe_put_string(
        %{
          "provider" => "openrouter",
          "model" => model,
          "usage" => usage,
          "provider_metadata" => normalize_value(provider_metadata)
        },
        "finish_reason",
        normalize_value(finish_reason)
      )

    %Result{
      content: Map.get(result, :text) || Map.get(result, "text"),
      content_format: :markdown,
      public_metadata: public_metadata,
      internal_metadata: internal_metadata
    }
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
      app_title: blank_to_nil(Keyword.get(merged_config, :app_title))
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

  defp normalized_usage(usage), do: normalize_value(usage || %{})

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
