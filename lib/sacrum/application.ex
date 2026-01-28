defmodule Sacrum.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SacrumWeb.Telemetry,
      Sacrum.Repo,
      {DNSCluster, query: Application.get_env(:sacrum, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sacrum.PubSub},
      # Start a worker by calling: Sacrum.Worker.start_link(arg)
      # {Sacrum.Worker, arg},
      # Start to serve requests, typically the last entry
      SacrumWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sacrum.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SacrumWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
