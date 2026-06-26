defmodule Sacrum.Realtime.Cdc.Config do
  @moduledoc false

  @default_tables ~w(
    tasks
    workflows
    workflow_steps
    step_transitions
    workflow_transitions
    step_executions
    task_runs
    session_logs
    task_sections
    task_dependencies
    code_refs
  )

  @spec start_consumer?() :: boolean()
  def start_consumer? do
    :sacrum
    |> Application.get_env(:cdc, [])
    |> Keyword.get(:start_consumer, false)
  end

  @spec walex_config() :: keyword()
  def walex_config do
    cdc_config = Application.get_env(:sacrum, :cdc, [])
    repo_config = Application.get_env(:sacrum, Sacrum.Repo, [])

    Keyword.merge(
      [
        name: Sacrum,
        publication: Keyword.fetch!(cdc_config, :publication),
        subscriptions: Keyword.get(cdc_config, :subscriptions, @default_tables),
        modules: Keyword.get(cdc_config, :modules, [Sacrum.Realtime.Cdc.WalExConsumer]),
        slot_name: Keyword.fetch!(cdc_config, :slot_name),
        durable_slot: Keyword.get(cdc_config, :durable_slot, true)
      ],
      database_config(repo_config)
    )
  end

  defp database_config(repo_config) do
    case Keyword.get(repo_config, :url) do
      nil ->
        [
          hostname: Keyword.get(repo_config, :hostname, "localhost"),
          username: Keyword.fetch!(repo_config, :username),
          password: Keyword.get(repo_config, :password, ""),
          port: Keyword.get(repo_config, :port, 5432),
          database: Keyword.fetch!(repo_config, :database)
        ]

      url ->
        [url: url]
    end
  end
end
