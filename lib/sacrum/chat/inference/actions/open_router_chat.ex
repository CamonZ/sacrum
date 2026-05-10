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
        timeout: Zoi.optional(Zoi.integer())
      }),
    output_schema:
      Zoi.object(%{
        text: Zoi.string(),
        model: Zoi.string(),
        usage: Zoi.optional(Zoi.map()),
        finish_reason: Zoi.optional(Zoi.any()),
        provider_metadata: Zoi.optional(Zoi.map())
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
      |> maybe_put(:receive_timeout, params[:timeout])

    model_spec = %{
      provider: :openrouter,
      id: params.model,
      base_url: params.base_url
    }

    with {:ok, response} <- ReqLLM.generate_text(model_spec, params.messages, opts),
         text when is_binary(text) and text != "" <- ReqLLM.Response.text(response) do
      {:ok,
       %{
         text: text,
         model: response.model,
         usage: ReqLLM.Response.usage(response) || %{},
         finish_reason: ReqLLM.Response.finish_reason(response),
         provider_metadata: response.provider_meta
       }}
    else
      nil -> {:error, :empty_openrouter_response}
      "" -> {:error, :empty_openrouter_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_options(params) do
    []
    |> maybe_put(:app_referer, params[:app_referer])
    |> maybe_put(:app_title, params[:app_title])
    |> maybe_put(:openrouter_usage, %{include: true})
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
