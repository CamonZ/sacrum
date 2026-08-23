# Workflow Step Ordering

Workflow steps use a zero-based, contiguous `step_order`: `0..n-1`.

- Creating without an order appends the step.
- Creating with an order inserts at that position and shifts later steps.
- Updating an order moves the step and keeps all sibling orders contiguous.
- Deleting a step compacts the remaining siblings.
- Positions outside the valid range are rejected. For compatibility with older
  one-based callers, a create request at the one-past-the-end position is
  treated as an append.

Step order and workflow entry are separate concepts. A non-null
`initial_step_id` is authoritative when it points to a step belonging to the
workflow, project, and owner. A nil pointer falls back to the lowest ordered
step without writing the pointer. Invalid non-null pointers fail closed.

The first step created in an empty workflow becomes the initial step. Deleting
the pointed-to step selects the lowest remaining step, and deleting the last
step clears the pointer. Step create, move, delete, and pointer reconciliation
run in one transaction serialized by the workflow row. Existing rows are not
backfilled or rewritten until an explicit mutation touches them.
