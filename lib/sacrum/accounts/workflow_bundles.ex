defmodule Sacrum.Accounts.WorkflowBundles do
  @moduledoc """
  User-scoped workflow bundle operations.

  Project authorization happens before the repository import so a caller
  cannot use manifest validation as a cross-project existence probe.
  """

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.WorkflowBundles, as: WorkflowBundlesRepo

  @spec import(String.t(), String.t(), term()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def import(user_id, project_id, bundle)
      when is_binary(user_id) and is_binary(project_id) do
    with {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]) do
      WorkflowBundlesRepo.import(user_id, project_id, bundle)
    end
  end
end
