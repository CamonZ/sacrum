---
name: review
description: Deprecated command; human review is represented by human_input workflow steps
---

# /review

Stop and explain that `/review` is deprecated.

Human review is no longer a task-level flag. Do not toggle or set
`needs_human_review`.

Move the task to the appropriate workflow position instead, such as assigning a
Human Review workflow or transitioning to a step whose `step_type` is
`human_input`. Clients should derive review state from `current_step_id` and the
current workflow step.
