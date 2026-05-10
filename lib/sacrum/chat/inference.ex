defmodule Sacrum.Chat.Inference do
  @moduledoc """
  Narrow Sacrum boundary for chat assistant inference.

  Sacrum owns chat session/message/event persistence and public projection. This
  boundary only prepares public transcript messages for a provider and normalizes
  the assistant result back into Sacrum-owned data.
  """

  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Schemas.ChatMessage

  @supported_provider_roles ~w(system user assistant)
  @sensitive_key_names ~w(authorization bearer password credential credentials)
  @sensitive_key_suffixes ~w(api_key auth_token access_token refresh_token token secret private_key)

  @spec generate([ChatMessage.t() | map()], keyword()) :: {:ok, Result.t()} | {:error, term()}
  def generate(messages, opts \\ []) when is_list(messages) do
    provider = Keyword.get(opts, :provider, configured_provider())
    provider_opts = Keyword.delete(opts, :provider)

    with {:ok, normalized_messages} <- normalize_messages(messages),
         {:ok, result} <- provider.generate(normalized_messages, provider_opts) do
      normalize_result(result)
    end
  end

  @spec normalize_messages([ChatMessage.t() | map()]) :: {:ok, [map()]} | {:error, term()}
  def normalize_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_message(message) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_inference_messages}
      {:ok, normalized_messages} -> {:ok, Enum.reverse(normalized_messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec scrub_secrets(term()) :: term()
  def scrub_secrets(%{} = value) do
    value
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Map.new(fn {key, nested_value} -> {key, scrub_secrets(nested_value)} end)
  end

  def scrub_secrets(value) when is_list(value), do: Enum.map(value, &scrub_secrets/1)
  def scrub_secrets(value), do: value

  defp normalize_message(%ChatMessage{role: role, content: content}) do
    normalize_message(%{role: role, content: content})
  end

  defp normalize_message(%{} = message) do
    role = message |> fetch_value(:role) |> normalize_role()
    content = fetch_value(message, :content)

    cond do
      is_nil(role) ->
        {:error, {:invalid_inference_message_role, fetch_value(message, :role)}}

      role not in @supported_provider_roles ->
        {:ok, nil}

      not is_binary(content) ->
        {:error, {:invalid_inference_message_content, role}}

      String.trim(content) == "" ->
        {:ok, nil}

      true ->
        {:ok, %{role: role, content: content}}
    end
  end

  defp normalize_message(message), do: {:error, {:invalid_inference_message, message}}

  defp normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_role), do: nil

  defp normalize_result(%Result{} = result) do
    cond do
      not is_binary(result.content) ->
        {:error, :invalid_inference_result_content}

      String.trim(result.content) == "" ->
        {:error, :empty_inference_result}

      result.content_format not in [:plain, :markdown] ->
        {:error, {:invalid_inference_result_format, result.content_format}}

      true ->
        {:ok,
         %Result{
           result
           | public_metadata: scrub_secrets(result.public_metadata || %{}),
             internal_metadata: scrub_secrets(result.internal_metadata || %{})
         }}
    end
  end

  defp normalize_result(%{} = result) do
    normalize_result(%Result{
      content: fetch_value(result, :content),
      content_format: fetch_value(result, :content_format) || :markdown,
      public_metadata: fetch_value(result, :public_metadata) || %{},
      internal_metadata: fetch_value(result, :internal_metadata) || %{}
    })
  end

  defp normalize_result(result), do: {:error, {:invalid_inference_result, result}}

  defp configured_provider do
    :sacrum
    |> Application.get_env(:chat_inference, [])
    |> Keyword.get(:provider, Sacrum.Chat.Inference.OpenRouter)
  end

  defp fetch_value(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.fetch!(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> then(fn normalized_key ->
      normalized_key in @sensitive_key_names or
        Enum.any?(@sensitive_key_suffixes, fn suffix ->
          normalized_key == suffix or String.ends_with?(normalized_key, "_#{suffix}")
        end)
    end)
  end
end
