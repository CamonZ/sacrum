defmodule Sacrum.Repo.Tasks do
  @moduledoc """
  CRUD operations for tasks, scoped to a project.

  ## Error Contract

  - `insert/2` returns `{:ok, task}` or `{:error, changeset}`
  - `update/1` returns `{:ok, task}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, task}` or `{:error, changeset}`
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Task

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.UuidPrefixResolver

  @doc """
  Lists tasks with optional filters.

  Options:
    - `:project_id` - filter by project
    - `:user_id` - filter by user
    - `:level` - filter by task level
    - `:priority` - filter by task priority
    - `:parent_id` - filter by parent task (via hierarchy)
    - `:blocked` - when false, exclude tasks with incomplete dependencies
    - `:search` - text search on title, description, or UUID prefix
    - `:status` - compatibility filter over persisted task status. New derivations
      write `"ready"` or `"done"`; use TaskRun queries for active run lifecycle.
    - `:step_id` - filter by workflow step ID
    - `:tags` - filter by tags (any match)
    - `:root_only` - when true, exclude tasks that have a parent
    - `:workflow_id` - filter by assigned workflow
    - `:archived` - when false (default), exclude archived tasks; when true, include all tasks
  """
  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts) do
    Task
    |> apply_filters(opts)
    |> apply_task_preloads(opts)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns tasks that are not completed and have no
  incomplete blockers for a project.
  """
  @spec ready(String.t(), String.t()) :: [Task.t()]
  def ready(project_id, user_id) do
    list_tasks(
      conditions: [
        project_id: project_id,
        user_id: user_id,
        blocked: false,
        completed: false
      ]
    )
  end

  defp apply_task_preloads(query, opts) do
    preloads = Keyword.get(opts, :preloads, [])
    apply_join_preloads(query, preloads)
  end

  defp apply_join_preloads(query, []), do: query

  defp apply_join_preloads(query, preloads) do
    Enum.reduce(preloads, query, fn assoc, q ->
      q
      |> join(:left, [t], a in assoc(t, ^assoc), as: ^assoc)
      |> preload([{^assoc, a}], [{^assoc, a}])
    end)
  end

  defp apply_filters(query, opts) do
    opts
    |> Keyword.get(:conditions)
    |> Enum.reduce(query, fn {key, value}, acc -> apply_filter(acc, key, value) end)
  end

  defp apply_filter(query, :user_id, nil), do: query

  defp apply_filter(query, :user_id, user_id) do
    where(query, [t], t.user_id == ^user_id)
  end

  defp apply_filter(query, :project_id, nil), do: query

  defp apply_filter(query, :project_id, project_id) do
    where(query, [t], t.project_id == ^project_id)
  end

  defp apply_filter(query, :level, nil), do: query

  defp apply_filter(query, :level, level) do
    where(query, [t], t.level == ^level)
  end

  defp apply_filter(query, :priority, nil), do: query

  defp apply_filter(query, :priority, priority) do
    where(query, [t], t.priority == ^priority)
  end

  defp apply_filter(query, :parent_id, nil), do: query

  defp apply_filter(query, :parent_id, parent_id) do
    where(query, [t], t.parent_id == ^parent_id)
  end

  defp apply_filter(query, :completed, nil), do: query

  defp apply_filter(query, :completed, false) do
    where(query, [t], is_nil(t.completed_at))
  end

  defp apply_filter(query, :completed, true) do
    where(query, [t], not is_nil(t.completed_at))
  end

  defp apply_filter(query, :blocked, nil), do: query

  defp apply_filter(query, :blocked, false) do
    # Exclude tasks that have incomplete (non-completed) dependencies
    from(t in query,
      where:
        t.id not in subquery(
          from(d in TaskDependency,
            join: dep in Task,
            on: dep.id == d.depends_on_id,
            where: is_nil(dep.completed_at),
            select: d.task_id,
            distinct: true
          )
        )
    )
  end

  defp apply_filter(query, :blocked, _), do: query

  defp apply_filter(query, :search, nil), do: query

  defp apply_filter(query, :search, term) do
    pattern = "%#{term}%"
    text_search = dynamic([t], ilike(t.title, ^pattern) or ilike(t.description, ^pattern))

    where(query, ^search_filter(term, text_search))
  end

  defp apply_filter(query, :status, nil), do: query

  defp apply_filter(query, :status, status) when is_binary(status) do
    where(query, [t], t.status == ^status)
  end

  defp apply_filter(query, :step_id, nil), do: query

  defp apply_filter(query, :step_id, step_id) do
    where(query, [t], t.current_step_id == ^step_id)
  end

  defp apply_filter(query, :tags, nil), do: query

  defp apply_filter(query, :tags, tags) when is_list(tags) do
    where(query, [t], fragment("? && ?", t.tags, ^tags))
  end

  defp apply_filter(query, :root_only, nil), do: query
  defp apply_filter(query, :root_only, false), do: query

  defp apply_filter(query, :root_only, true) do
    where(query, [t], is_nil(t.parent_id))
  end

  defp apply_filter(query, :workflow_id, nil), do: query

  defp apply_filter(query, :workflow_id, workflow_id) do
    where(query, [t], t.workflow_id == ^workflow_id)
  end

  defp apply_filter(query, :archived, nil), do: query

  defp apply_filter(query, :archived, false) do
    where(query, [t], t.archived == false)
  end

  defp apply_filter(query, :archived, true), do: query

  defp search_filter(term, text_search) do
    case Ecto.UUID.cast(term) do
      {:ok, uuid} ->
        dynamic([t], ^text_search or t.id == ^uuid)

      :error ->
        search_prefix_filter(term, text_search)
    end
  end

  defp search_prefix_filter(term, text_search) do
    if uuid_prefix_search_term?(term) do
      prefix_length = String.length(term)
      normalized_prefix = String.downcase(term)

      dynamic(
        [t],
        ^text_search or
          fragment("left(?::text, ?)", t.id, ^prefix_length) == ^normalized_prefix
      )
    else
      text_search
    end
  end

  defp uuid_prefix_search_term?(term) when is_binary(term) do
    Regex.match?(
      ~r/\A[0-9a-f]{1,8}(-[0-9a-f]{0,4}(-[0-9a-f]{0,4}(-[0-9a-f]{0,4}(-[0-9a-f]{0,12})?)?)?)?\z/i,
      term
    )
  end

  @spec find_by_uuid_prefix(String.t(), String.t(), String.t()) ::
          {:ok, Task.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def find_by_uuid_prefix(prefix, project_id, user_id) do
    query =
      from(t in Task,
        where: t.project_id == ^project_id and t.user_id == ^user_id
      )

    UuidPrefixResolver.find_by_prefix(query, prefix, preloads: [:sections, :parent])
  end

  @spec insert(Project.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Project{id: project_id, user_id: user_id}, attrs) when is_binary(user_id) do
    insert(project_id, user_id, attrs)
  end

  def insert(%Project{id: project_id}, attrs) do
    insert(project_id, attrs)
  end

  @spec insert(String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, attrs) when is_binary(project_id) and is_map(attrs) do
    do_insert(%Task{project_id: project_id}, project_id, nil, attrs)
  end

  defoverridable insert: 2

  @spec insert(String.t(), String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, user_id, attrs) when is_binary(project_id) and is_binary(user_id) do
    do_insert(%Task{project_id: project_id, user_id: user_id}, project_id, user_id, attrs)
  end

  defp do_insert(%Task{} = task, project_id, user_id, attrs) do
    with {:ok, prepared_attrs} <- prepare_workflow_attrs(attrs, project_id, user_id) do
      case task |> Task.create_changeset(prepared_attrs) |> Repo.insert() do
        {:ok, task} -> {:ok, Repo.preload(task, :sections, force: true)}
        error -> error
      end
    end
  end

  defp prepare_workflow_attrs(attrs, project_id, user_id) do
    case Map.fetch(attrs, :workflow_id) do
      :error ->
        {:ok, assign_default_workflow_attrs(attrs, project_id)}

      {:ok, workflow_id} ->
        seed_provided_workflow(attrs, project_id, user_id, workflow_id)
    end
  end

  defp seed_provided_workflow(attrs, project_id, user_id, workflow_id) do
    conditions = [id: workflow_id, project_id: project_id]
    conditions = if user_id, do: Keyword.put(conditions, :user_id, user_id), else: conditions

    case Repo.get_by(Sacrum.Repo.Schemas.Workflow, conditions) do
      nil ->
        changeset =
          %Task{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:workflow_id, "does not exist in this project")

        {:error, changeset}

      workflow ->
        step = resolve_initial_step(workflow)
        {:ok, Map.put_new(attrs, :current_step_id, step.id)}
    end
  end

  @doc """
  Assigns the project's default workflow and its initial step into `attrs`
  unless `:workflow_id` / `"workflow_id"` is already provided. If no default
  workflow exists, returns attrs unchanged so the NOT NULL constraint surfaces
  the error at insert time.
  """
  @spec assign_default_workflow_attrs(map(), String.t()) :: map()
  def assign_default_workflow_attrs(attrs, project_id)
      when not is_map_key(attrs, :workflow_id) and not is_map_key(attrs, "workflow_id") do
    case find_default_workflow(project_id) do
      nil ->
        attrs

      workflow ->
        step = resolve_initial_step(workflow)

        attrs
        |> Map.put(:workflow_id, workflow.id)
        |> Map.put(:current_step_id, step.id)
    end
  end

  def assign_default_workflow_attrs(attrs, _project_id), do: attrs

  defp find_default_workflow(project_id) do
    Repo.one(
      from(w in Sacrum.Repo.Schemas.Workflow,
        where: w.project_id == ^project_id and w.is_default == true,
        limit: 1
      )
    )
  end

  defp resolve_initial_step(%{initial_step_id: step_id}) when not is_nil(step_id) do
    Repo.get!(Sacrum.Repo.Schemas.WorkflowStep, step_id)
  end

  defp resolve_initial_step(workflow) do
    Repo.one!(
      from(s in Sacrum.Repo.Schemas.WorkflowStep,
        where: s.workflow_id == ^workflow.id,
        order_by: s.step_order,
        limit: 1
      )
    )
  end

  @spec delete(Task.t(), keyword()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Task{} = task, opts \\ []) do
    cascade = Keyword.get(opts, :cascade, true)

    unless cascade do
      Repo.update_all(
        from(t in Task, where: t.parent_id == ^task.id),
        set: [parent_id: nil]
      )
    end

    Repo.delete(task)
  end
end
