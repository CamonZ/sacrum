defmodule Sacrum.Realtime.Cdc.Supervisor do
  @moduledoc false

  use Supervisor

  alias Sacrum.Realtime.Cdc.Config

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        Sacrum.Realtime.Cdc.Projector
      ] ++ walex_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp walex_children do
    if Config.start_consumer?() do
      [{WalEx.Supervisor, Config.walex_config()}]
    else
      []
    end
  end
end
