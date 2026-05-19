defmodule Sacrum.Repo.Artifacts do
  @moduledoc """
  Database operations for project-scoped artifacts.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Artifact

  import Ecto.Query
  import Sacrum.Chat.Guards

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Schemas.Project

  @default_limit 50
  @public_redaction_states ~w(not_needed redacted)

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def insert(user_id, project_id, attrs \\ %{})
      when is_user_project_scope(user_id, project_id) and is_attrs(attrs) do
    if project_exists?(user_id, project_id) do
      %Artifact{user_id: user_id, project_id: project_id}
      |> Artifact.create_changeset(attrs)
      |> Repo.insert()
    else
      {:error, :not_found}
    end
  end

  @spec list_public_for_project(String.t(), String.t(), keyword()) :: [Artifact.t()]
  def list_public_for_project(user_id, project_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_options(opts) do
    Artifact
    |> where(
      [artifact],
      artifact.user_id == ^user_id and artifact.project_id == ^project_id and
        artifact.visibility == "public" and artifact.redaction_state in ^@public_redaction_states
    )
    |> order_by([artifact], desc: artifact.inserted_at, desc: artifact.id)
    |> limit(^limit_option(opts))
    |> Repo.all()
  end

  defp project_exists?(user_id, project_id) do
    Project
    |> where([project], project.id == ^project_id and project.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp limit_option(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> min(@default_limit)
    |> max(1)
  end
end
