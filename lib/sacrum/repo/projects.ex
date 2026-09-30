defmodule Sacrum.Repo.Projects do
  @moduledoc """
  CRUD operations for projects.

  ## Error Contract

  - `get/1` returns `{:ok, project}` or `{:error, :not_found}`
  - `get!/1` returns project or raises
  - `get_by/1` returns `{:ok, project}` or `{:error, :not_found}`
  - `all/0` returns `[project]`
  - `insert/2` returns `{:ok, project}` or `{:error, changeset}`
  - `update/2` returns `{:ok, project}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, project}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.User
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Project

  @spec insert(User.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def insert(%User{id: user_id}, attrs), do: insert(user_id, attrs)

  @spec insert(String.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) do
    project_changeset = Project.create_changeset(%Project{user_id: user_id}, attrs)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:project, project_changeset)
      |> Ecto.Multi.run(:default_harness, fn _repo, _changes ->
        case default_harness(attrs) do
          {:ok, harness} ->
            {:ok, harness}

          {:error, message} ->
            {:error, Ecto.Changeset.add_error(project_changeset, :base, message)}
        end
      end)
      |> Ecto.Multi.insert(:workflow, fn %{project: project} ->
        Workflow.create_changeset(
          %Workflow{project_id: project.id, user_id: user_id},
          %{name: "Backlog", is_default: true}
        )
      end)
      |> Ecto.Multi.insert(:step, fn %{workflow: workflow, default_harness: harness} ->
        WorkflowStep.create_changeset(
          %WorkflowStep{
            workflow_id: workflow.id,
            project_id: workflow.project_id,
            user_id: user_id
          },
          %{name: "Backlog", step_order: 1, harness: harness}
        )
      end)
      |> Ecto.Multi.update(:workflow_with_step, fn %{workflow: workflow, step: step} ->
        Workflow.update_changeset(workflow, %{initial_step_id: step.id})
      end)

    case Repo.transaction(multi) do
      {:ok, %{project: project}} -> {:ok, project}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  defp default_harness(attrs) do
    case {capability(attrs, :codex_installed), capability(attrs, :claude_installed)} do
      {:missing, :missing} ->
        {:ok, "codex"}

      {true, false} ->
        {:ok, "codex"}

      {true, true} ->
        {:ok, "codex"}

      {false, true} ->
        {:ok, "claude"}

      {false, false} ->
        {:error, "at least one supported harness (Codex or Claude) must be installed"}

      {:missing, _claude_installed} ->
        {:error, "codex_installed and claude_installed must be supplied together"}

      {_codex_installed, :missing} ->
        {:error, "codex_installed and claude_installed must be supplied together"}

      _invalid_capability ->
        {:error, "codex_installed and claude_installed must be booleans"}
    end
  end

  defp capability(attrs, key) do
    case Map.fetch(attrs, key) do
      :error ->
        case Map.fetch(attrs, Atom.to_string(key)) do
          :error -> :missing
          result -> capability_value(result)
        end

      result ->
        capability_value(result)
    end
  end

  defp capability_value({:ok, value}) when is_boolean(value), do: value
  defp capability_value({:ok, nil}), do: :missing
  defp capability_value(_invalid), do: :invalid

  defoverridable insert: 2

  @spec update(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> Repo.update()
  end
end
