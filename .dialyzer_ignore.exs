[
  # Ecto.Multi opaque MapSet false positives (known dialyzer/Ecto issue)
  {"lib/sacrum/repo/task_workflows.ex", :call_without_opaque},
  # MapSet opaque type passed through recursive calls
  {"lib/sacrum/repo/task_dependencies.ex", :call_without_opaque},
  {"lib/sacrum/repo/task_dependencies.ex", :call_with_opaque}
]
