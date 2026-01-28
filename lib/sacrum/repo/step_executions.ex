defmodule Sacrum.Repo.StepExecutions do
  @moduledoc """
  Operations for step execution audit trail.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  def get(id) do
    case Repo.get(StepExecution, id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  def get!(id), do: Repo.get!(StepExecution, id)

  def list_for_task(task_id) when is_binary(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  def insert(attrs) do
    %StepExecution{}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
  end
end
