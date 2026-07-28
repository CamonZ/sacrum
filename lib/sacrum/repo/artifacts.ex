defmodule Sacrum.Repo.Artifacts do
  @moduledoc """
  Database operations for project-scoped artifacts.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Artifact

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Schemas.ArtifactLink
  alias Sacrum.Repo.Schemas.Project

  @default_limit 50
  @default_offset 0

  defguardp is_user_project_scope(user_id, project_id)
            when is_binary(user_id) and is_binary(project_id)

  defguardp is_attrs(attrs) when is_map(attrs)
  defguardp is_options(opts) when is_list(opts)

  @spec get_in_scope(String.t(), String.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get_in_scope(user_id, artifact_id)
      when is_binary(user_id) and is_binary(artifact_id) do
    user_id
    |> artifact_in_scope_query(artifact_id)
    |> fetch_one()
  end

  @spec get_in_scope_for_update(String.t(), String.t()) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def get_in_scope_for_update(user_id, artifact_id)
      when is_binary(user_id) and is_binary(artifact_id) do
    user_id
    |> artifact_in_scope_query(artifact_id)
    |> lock("FOR UPDATE")
    |> fetch_one()
  end

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

  @spec update(Artifact.t(), map()) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def update(%Artifact{} = artifact, attrs) when is_attrs(attrs) do
    artifact
    |> Artifact.update_changeset(attrs)
    |> Repo.update()
  end

  @spec list_for_project(String.t(), String.t(), keyword()) :: [Artifact.t()]
  def list_for_project(user_id, project_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_options(opts) do
    Artifact
    |> where_in_scope(user_id, project_id)
    |> apply_artifact_order()
    |> apply_offset(opts)
    |> apply_limit(opts)
    |> Repo.all()
  end

  @spec list_for_subject(String.t(), String.t(), String.t(), String.t(), keyword()) :: [
          Artifact.t()
        ]
  def list_for_subject(user_id, project_id, subject_type, subject_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_options(opts) do
    Artifact
    |> join(:inner, [artifact], link in ArtifactLink, on: link.artifact_id == artifact.id)
    |> where_in_scope(user_id, project_id)
    |> where_subject_link_in_scope(user_id, project_id, subject_type, subject_id)
    |> distinct(true)
    |> apply_artifact_order()
    |> apply_offset(opts)
    |> apply_limit(opts)
    |> Repo.all()
  end

  defp where_in_scope(query, user_id, project_id) do
    where(
      query,
      [artifact],
      artifact.user_id == ^user_id and artifact.project_id == ^project_id
    )
  end

  defp artifact_in_scope_query(user_id, artifact_id) do
    where(Artifact, [artifact], artifact.id == ^artifact_id and artifact.user_id == ^user_id)
  end

  defp fetch_one(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      artifact -> {:ok, artifact}
    end
  end

  defp where_subject_link_in_scope(query, user_id, project_id, subject_type, subject_id) do
    where(
      query,
      [_artifact, link],
      link.user_id == ^user_id and link.project_id == ^project_id and
        link.subject_type == ^subject_type and link.subject_id == ^subject_id
    )
  end

  defp apply_artifact_order(query) do
    order_by(query, [artifact], desc: artifact.inserted_at, desc: artifact.id)
  end

  defp apply_limit(query, opts) do
    limit(query, ^limit_option(opts))
  end

  defp apply_offset(query, opts) do
    offset(query, ^offset_option(opts))
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

  defp offset_option(opts) do
    opts
    |> Keyword.get(:offset, @default_offset)
    |> max(0)
  end
end
