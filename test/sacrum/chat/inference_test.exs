defmodule Sacrum.Chat.InferenceTest do
  use ExUnit.Case, async: true

  alias Sacrum.Chat.Inference
  alias Sacrum.Chat.Inference.OpenRouter
  alias Sacrum.Chat.Inference.Result

  defmodule FakeProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:fake_provider_messages, messages})
      end

      {:ok,
       %Result{
         content: "Assistant response to #{List.last(messages).content}",
         content_format: :markdown,
         public_metadata: %{
           "provider" => "fake",
           "api_key" => "sk-public-secret",
           "apiKey" => "sk-camel-secret",
           "x-api-key" => "sk-dash-secret",
           "client_secret" => "client-secret"
         },
         internal_metadata: %{
           "trace_id" => "trace-1",
           "authorization" => "Bearer internal-secret",
           "private_key" => "private-secret",
           "refreshToken" => "refresh-secret"
         }
       }}
    end
  end

  describe "generate/2" do
    test "runs a fake provider and returns a normalized assistant result" do
      messages = [
        %{role: :system, content: "Stay concise."},
        %{role: :user, content: "Draft a reply"},
        %{role: :status, content: "Status messages are not sent to providers"}
      ]

      assert {:ok, result} =
               Inference.generate(messages, provider: FakeProvider, test_pid: self())

      assert_receive {:fake_provider_messages,
                      [
                        %{role: "system", content: "Stay concise."},
                        %{role: "user", content: "Draft a reply"}
                      ]}

      assert %Result{} = result
      assert result.content == "Assistant response to Draft a reply"
      assert result.content_format == :markdown
      assert result.public_metadata == %{"provider" => "fake"}
      assert result.internal_metadata == %{"trace_id" => "trace-1"}
    end
  end

  describe "OpenRouter.generate/2" do
    test "requires real provider configuration before making a provider call" do
      messages = [%{role: "user", content: "hello"}]
      missing_config = [api_key: nil, base_url: nil, model: nil]

      refute OpenRouter.configured?(config: missing_config)

      assert {:error, {:missing_openrouter_config, missing}} =
               OpenRouter.generate(messages, config: missing_config)

      assert missing == [:api_key, :base_url, :model]
    end
  end
end
