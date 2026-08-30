defmodule Sacrum.Repo.Schemas.WorkflowTransition do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_transitions" do
    field :label, :string

    belongs_to :from_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :to_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :target_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(transition, attrs) do
    transition
    |> cast(attrs, [:label, :from_workflow_id, :to_workflow_id, :target_step_id])
    |> validate_required([:from_workflow_id, :to_workflow_id])
    |> validate_scope()
    |> foreign_key_constraint(:from_workflow_id)
    |> foreign_key_constraint(:to_workflow_id)
    |> foreign_key_constraint(:target_step_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:from_workflow_id, :to_workflow_id],
      message: "transition already exists between these workflows"
    )
  end

  defp validate_scope(changeset) do
    from_id = get_field(changeset, :from_workflow_id)
    to_id = get_field(changeset, :to_workflow_id)

    case load_endpoints(from_id, to_id) do
      {from_workflow, to_workflow} ->
        changeset
        |> reject_cross_scope(from_workflow, to_workflow)
        |> reject_caller_mismatch(from_workflow)

      :skip ->
        changeset
    end
  end

  defp load_endpoints(from_id, to_id) when is_binary(from_id) and is_binary(to_id) do
    workflows =
      Map.new(
        Repo.all(from(workflow in Workflow, where: workflow.id in ^[from_id, to_id])),
        &{&1.id, &1}
      )

    case {workflows[from_id], workflows[to_id]} do
      {%Workflow{} = from_workflow, %Workflow{} = to_workflow} ->
        {from_workflow, to_workflow}

      _ ->
        :skip
    end
  end

  defp load_endpoints(_from_id, _to_id), do: :skip

  defp reject_cross_scope(changeset, from_workflow, to_workflow) do
    if from_workflow.project_id == to_workflow.project_id and
         from_workflow.user_id == to_workflow.user_id do
      changeset
    else
      add_error(
        changeset,
        :to_workflow_id,
        "must belong to the same project and user as from_workflow_id"
      )
    end
  end

  defp reject_caller_mismatch(changeset, from_workflow) do
    user_id = get_field(changeset, :user_id)
    project_id = get_field(changeset, :project_id)

    cond do
      is_binary(user_id) and from_workflow.user_id != user_id ->
        add_error(changeset, :from_workflow_id, "is not accessible to the current user")

      is_binary(project_id) and from_workflow.project_id != project_id ->
        add_error(changeset, :project_id, "must match the source workflow project")

      true ->
        changeset
    end
  end
end
