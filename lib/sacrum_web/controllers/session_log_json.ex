defmodule SacrumWeb.SessionLogJSON do
  alias Sacrum.Repo.Schemas.SessionLog

  def index(%{logs: logs}) do
    %{data: for(log <- logs, do: data(log))}
  end

  def show(%{log: log}) do
    %{data: data(log)}
  end

  defp data(%SessionLog{} = log) do
    %{
      id: log.id,
      step_execution_id: log.step_execution_id,
      content: log.content,
      inserted_at: log.inserted_at,
      updated_at: log.updated_at
    }
  end
end
