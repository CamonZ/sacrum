defmodule Sacrum.ChatInferenceCase do
  @moduledoc false

  import ExUnit.Assertions

  defmodule FakeProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:fake_provider_messages, messages})
      end

      {:ok,
       %Sacrum.Chat.Inference.Result{
         content: "Persisted assistant output",
         content_format: :markdown,
         public_metadata: %{
           "provider" => "fake",
           "model" => "fake-model",
           "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
         },
         internal_metadata: %{
           "trace_id" => "trace-1",
           "raw_provider_payload" => %{
             "id" => "provider-response-1",
             "headers" => %{
               "authorization" => "Bearer raw-secret",
               "x-api-key" => "sk-header-secret",
               "content-type" => "application/json"
             },
             "usage" => %{"total_tokens" => 12}
           },
           "api_key" => "sk-internal-secret"
         }
       }}
    end
  end

  defmodule ErrorProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, :error_provider_called)
      end

      {:error,
       {:provider_failed,
        %{
          reason: "rate_limited",
          api_key: "sk-provider-secret",
          nested: %{authorization: "Bearer provider-secret"}
        }}}
    end
  end

  defmodule BlockingProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      started_message = Keyword.get(opts, :started_message, :blocking_provider_started)
      release_message = Keyword.get(opts, :release_message, :release_provider)
      released_message = Keyword.get(opts, :released_message, :blocking_provider_released)

      send(test_pid, {started_message, self(), messages})

      receive do
        ^release_message -> :ok
      after
        2_000 -> raise "blocking provider was not released"
      end

      send(test_pid, {released_message, self()})

      {:ok,
       %Sacrum.Chat.Inference.Result{
         content: Keyword.get(opts, :content, "Blocking assistant output"),
         content_format: :markdown,
         public_metadata: Keyword.get(opts, :public_metadata, %{"provider" => "blocking"}),
         internal_metadata:
           Keyword.get(opts, :internal_metadata, %{"trace_id" => "blocking-trace"})
       }}
    end
  end

  def configure_async_inference(provider, opts) do
    previous = Application.get_env(:sacrum, :chat_inference, [])

    Application.put_env(
      :sacrum,
      :chat_inference,
      previous
      |> Keyword.merge(async: true)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:async_opts, opts)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:sacrum, :chat_inference, previous) end)
  end

  def eventually(fun, timeout \\ 1_000, interval \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      nil ->
        wait_or_fail(fun, deadline, interval)

      false ->
        wait_or_fail(fun, deadline, interval)

      value ->
        value
    end
  end

  defp wait_or_fail(fun, deadline, interval) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("condition was not met before timeout")
    else
      Process.sleep(interval)
      do_eventually(fun, deadline, interval)
    end
  end
end
