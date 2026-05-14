defmodule Sacrum.Chat.Inference.Actions.OpenRouterChat do
  @moduledoc """
  Jido action that performs one OpenRouter-compatible chat completion.

  Sacrum callers should go through `Sacrum.Chat.Inference`; this action is the
  provider orchestration substrate and intentionally returns a normalized map.
  """

  use Jido.Action,
    name: "sacrum_openrouter_chat",
    description: "Generate a Sacrum chat assistant response through OpenRouter",
    category: "chat",
    tags: ["sacrum", "chat", "openrouter", "inference"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        messages: Zoi.min(Zoi.list(Zoi.map()), 1),
        model: Zoi.string(),
        base_url: Zoi.string(),
        api_key: Zoi.string(),
        app_referer: Zoi.optional(Zoi.string()),
        app_title: Zoi.optional(Zoi.string()),
        temperature: Zoi.optional(Zoi.float()),
        max_tokens: Zoi.optional(Zoi.integer()),
        reasoning_effort: Zoi.optional(Zoi.any()),
        provider_options: Zoi.optional(Zoi.any()),
        timeout: Zoi.optional(Zoi.integer())
      }),
    output_schema:
      Zoi.object(%{
        text: Zoi.string(),
        model: Zoi.string(),
        usage: Zoi.optional(Zoi.map()),
        finish_reason: Zoi.optional(Zoi.any()),
        provider_metadata: Zoi.optional(Zoi.map()),
        reasoning_text: Zoi.optional(Zoi.string()),
        reasoning_details: Zoi.optional(Zoi.list(Zoi.any())),
        reasoning_tokens: Zoi.optional(Zoi.integer())
      })

  @impl true
  def run(params, _context) do
    opts =
      [
        api_key: params.api_key,
        base_url: params.base_url,
        max_retries: 0,
        provider_options: provider_options(params)
      ]
      |> maybe_put(:temperature, params[:temperature])
      |> maybe_put(:max_tokens, params[:max_tokens])
      |> maybe_put(:reasoning_effort, params[:reasoning_effort])
      |> maybe_put(:receive_timeout, params[:timeout])

    model_spec = %{
      provider: :openrouter,
      id: params.model,
      base_url: params.base_url
    }

    with {:ok, response} <- ReqLLM.generate_text(model_spec, params.messages, opts),
         text when is_binary(text) and text != "" <- ReqLLM.Response.text(response) do
      result =
        %{
          text: text,
          model: response.model,
          usage: ReqLLM.Response.usage(response) || %{},
          finish_reason: ReqLLM.Response.finish_reason(response),
          provider_metadata: response.provider_meta
        }
        |> maybe_put_result(:reasoning_text, ReqLLM.Response.thinking(response))
        |> maybe_put_result(:reasoning_details, reasoning_details(response))
        |> maybe_put_result(:reasoning_tokens, ReqLLM.Response.reasoning_tokens(response))

      {:ok, result}
    else
      nil -> {:error, :empty_openrouter_response}
      "" -> {:error, :empty_openrouter_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_options(params) do
    params
    |> Map.get(:provider_options)
    |> normalize_provider_options()
    |> maybe_put(:app_referer, params[:app_referer])
    |> maybe_put(:app_title, params[:app_title])
    |> maybe_put(:openrouter_usage, %{include: true})
  end

  defp reasoning_details(%ReqLLM.Response{message: %{reasoning_details: details}})
       when is_list(details) do
    details
  end

  defp reasoning_details(_response), do: []

  defp normalize_provider_options(options) when is_map(options) do
    options
    |> Map.to_list()
    |> normalize_provider_options()
  end

  defp normalize_provider_options(options) when is_list(options) do
    Enum.filter(options, fn
      {key, _value} when is_atom(key) -> true
      _other -> false
    end)
  end

  defp normalize_provider_options(_options), do: []

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, _key, []), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp maybe_put_result(map, _key, nil), do: map
  defp maybe_put_result(map, _key, ""), do: map
  defp maybe_put_result(map, _key, []), do: map
  defp maybe_put_result(map, _key, 0), do: map
  defp maybe_put_result(map, key, value), do: Map.put(map, key, value)
end
