defmodule Sacrum.Repo.Artifacts do
  @moduledoc """
  Database operations for project artifacts.

  Visibility scoping is enforced here: callers must explicitly opt in to
  including internal artifacts.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Artifact

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}

  @spec create(String.t(), String.t(), map()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def create(user_id, project_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.put(:project_id, project_id)
      |> Map.put(:user_id, user_id)

    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_for_project(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def get_for_project(user_id, artifact_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(artifact_id) and is_binary(project_id) do
    Artifact
    |> where([a], a.id == ^artifact_id and a.user_id == ^user_id and a.project_id == ^project_id)
    |> maybe_filter_public(Keyword.get(opts, :internal, false))
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  @spec list_by_project(String.t(), String.t(), keyword()) :: [Artifact.t()]
  def list_by_project(user_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(project_id) do
    Artifact
    |> where([a], a.user_id == ^user_id and a.project_id == ^project_id)
    |> maybe_filter_public(Keyword.get(opts, :internal, false))
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> Repo.all()
  end

  @spec list_for_subject(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          [Artifact.t()]
  def list_for_subject(user_id, subject_type, subject_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(subject_type) and is_binary(subject_id) and
             is_binary(project_id) do
    Artifact
    |> join(:inner, [a], l in ArtifactLink, on: l.artifact_id == a.id)
    |> where(
      [a, l],
      a.user_id == ^user_id and a.project_id == ^project_id and
        l.subject_type == ^subject_type and l.subject_id == ^subject_id and
        l.project_id == ^project_id
    )
    |> maybe_filter_public(Keyword.get(opts, :internal, false))
    |> order_by([a, _l], desc: a.inserted_at, desc: a.id)
    |> Repo.all()
  end

  defp maybe_filter_public(query, true), do: query

  defp maybe_filter_public(query, _internal) do
    where(query, [a], a.visibility == "public")
  end
end
