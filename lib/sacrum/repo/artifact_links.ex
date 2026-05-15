defmodule Sacrum.Repo.ArtifactLinks do
  @moduledoc """
  Database operations for artifact links.

  `add_link/1` validates that the link's `project_id` matches the artifact's
  `project_id`; cross-project links are rejected with `{:error, :unauthorized}`.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ArtifactLink

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}

  @spec add_link(map()) ::
          {:ok, ArtifactLink.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :not_found}
  def add_link(attrs) when is_map(attrs) do
    artifact_id = fetch(attrs, :artifact_id)
    project_id = fetch(attrs, :project_id)

    with {:ok, artifact} <- fetch_artifact(artifact_id),
         :ok <- ensure_same_project(artifact, project_id) do
      prepared =
        attrs
        |> Map.put_new_lazy(:relationship_kind, fn -> "attached_to" end)
        |> Map.put_new_lazy(:user_id, fn -> artifact.user_id end)

      %ArtifactLink{}
      |> ArtifactLink.changeset(prepared)
      |> Repo.insert()
    end
  end

  @spec list_for_subject(String.t(), String.t(), String.t()) :: [ArtifactLink.t()]
  def list_for_subject(subject_type, subject_id, project_id)
      when is_binary(subject_type) and is_binary(subject_id) and is_binary(project_id) do
    Repo.all(
      from(l in ArtifactLink,
        where:
          l.subject_type == ^subject_type and l.subject_id == ^subject_id and
            l.project_id == ^project_id
      )
    )
  end

  defp fetch(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp fetch_artifact(nil), do: {:error, :not_found}

  defp fetch_artifact(id) do
    case Repo.get(Artifact, id) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  defp ensure_same_project(%Artifact{project_id: artifact_project_id}, project_id)
       when artifact_project_id == project_id,
       do: :ok

  defp ensure_same_project(_artifact, _project_id), do: {:error, :unauthorized}
end
