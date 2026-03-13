defmodule Sacrum.DaemonRegistry do
  @moduledoc """
  GenServer that tracks connected daemon clients per project.

  Daemons join project channels with client_type="daemon" and are registered here.
  Provides functions to query daemon presence and count per project.
  """

  use GenServer

  require Logger

  # Client API

  @doc """
  Start the daemon registry as part of the application supervision tree.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a daemon client for a project.

  Returns the new count of daemons for the project.
  """
  @spec register_daemon(String.t()) :: pos_integer()
  def register_daemon(project_id) do
    GenServer.call(__MODULE__, {:register_daemon, project_id})
  end

  @doc """
  Unregister a daemon client for a project.

  Returns the new count of daemons for the project (0 or more).
  """
  @spec unregister_daemon(String.t()) :: non_neg_integer()
  def unregister_daemon(project_id) do
    GenServer.call(__MODULE__, {:unregister_daemon, project_id})
  end

  @doc """
  Check if a daemon is connected for a given project.

  Returns true if at least one daemon is connected, false otherwise.
  """
  @spec daemon_connected?(String.t()) :: boolean()
  def daemon_connected?(project_id) do
    GenServer.call(__MODULE__, {:daemon_connected?, project_id})
  end

  @doc """
  Get the count of connected daemons for a project.
  """
  @spec daemon_count(String.t()) :: non_neg_integer()
  def daemon_count(project_id) do
    GenServer.call(__MODULE__, {:daemon_count, project_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Use a map to store project_id -> daemon_count
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_daemon, project_id}, _from, state) do
    new_state = Map.update(state, project_id, 1, &(&1 + 1))
    count = Map.get(new_state, project_id)
    Logger.info("[DaemonRegistry] Daemon registered for project #{project_id}. Count: #{count}")
    {:reply, count, new_state}
  end

  @impl true
  def handle_call({:unregister_daemon, project_id}, _from, state) do
    current_count = Map.get(state, project_id, 0)

    new_state =
      if current_count > 1 do
        Map.put(state, project_id, current_count - 1)
      else
        Map.delete(state, project_id)
      end

    new_count = max(0, current_count - 1)

    Logger.info(
      "[DaemonRegistry] Daemon unregistered for project #{project_id}. Count: #{new_count}"
    )

    {:reply, new_count, new_state}
  end

  @impl true
  def handle_call({:daemon_connected?, project_id}, _from, state) do
    {:reply, Map.has_key?(state, project_id), state}
  end

  @impl true
  def handle_call({:daemon_count, project_id}, _from, state) do
    count = Map.get(state, project_id, 0)
    {:reply, count, state}
  end
end
