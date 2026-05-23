defmodule Sacrum.Chat.InferenceTest do
  use ExUnit.Case, async: false

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

  defmodule CapturingProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:capturing_provider, messages, opts})
      end

      {:ok,
       %Result{
         content: "ok",
         content_format: :markdown,
         public_metadata: %{},
         internal_metadata: %{}
       }}
    end
  end

  describe "generate/2 with system_prompt and tools" do
    test "prepends the system_prompt as a synthetic system message" do
      tools = [
        %{
          "type" => "function",
          "function" => %{"name" => "start_authoring", "parameters" => %{}}
        }
      ]

      assert {:ok, _result} =
               Inference.generate(
                 [%{role: :user, content: "Hi"}],
                 provider: CapturingProvider,
                 system_prompt: "You are Vertebrae.",
                 tools: tools,
                 test_pid: self()
               )

      assert_receive {:capturing_provider, messages, opts}

      assert [
               %{role: "system", content: "You are Vertebrae."},
               %{role: "user", content: "Hi"}
             ] = messages

      assert Keyword.get(opts, :tools) == tools
      assert Keyword.get(opts, :system_prompt) == "You are Vertebrae."
    end

    test "does not prepend a system message when system_prompt is nil" do
      assert {:ok, _result} =
               Inference.generate(
                 [%{role: :user, content: "Hi"}],
                 provider: CapturingProvider,
                 test_pid: self()
               )

      assert_receive {:capturing_provider, messages, opts}

      assert [%{role: "user", content: "Hi"}] = messages
      refute Keyword.has_key?(opts, :tools)
    end

    test "does not prepend a duplicate system message when the head is already system-role" do
      assert {:ok, _result} =
               Inference.generate(
                 [
                   %{role: :system, content: "caller-owned system"},
                   %{role: :user, content: "Hi"}
                 ],
                 provider: CapturingProvider,
                 system_prompt: "default vertebrae prompt",
                 test_pid: self()
               )

      assert_receive {:capturing_provider, messages, _opts}

      assert [
               %{role: "system", content: "caller-owned system"},
               %{role: "user", content: "Hi"}
             ] = messages

      assert Enum.count(messages, &(&1.role == "system")) == 1
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

  describe "timeout/1" do
    test "uses explicit opts before runtime configuration" do
      original_config = Application.get_env(:sacrum, :chat_inference, [])

      on_exit(fn ->
        Application.put_env(:sacrum, :chat_inference, original_config)
      end)

      Application.put_env(
        :sacrum,
        :chat_inference,
        Keyword.put(original_config, :timeout, 90_000)
      )

      assert Inference.timeout() == 90_000
      assert Inference.timeout(timeout: 45_000) == 45_000
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
