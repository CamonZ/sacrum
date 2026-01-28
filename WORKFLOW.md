# WORKFLOW.md

This file describes how to use `vtb` (vertebrae) to pick up and work through tickets.

## Finding Work

1. List tickets to find anything already in progress:

```bash
vtb list -s in_progress
```

2. If a ticket is in progress, check if it has children:

```bash
vtb show <ticket-id>
```

3. If it has children, recurse: find the deepest child that is `in_progress`. Keep running `vtb show` on in-progress children until you reach a leaf ticket (one with no in-progress children).

4. If nothing is in progress, pick a ticket from backlog and advance it:

```bash
vtb workflow advance <ticket-id>
```

Then check for children and recurse as above.

## Working a Ticket

1. Read the ticket details with `vtb show <ticket-id>` to understand the steps, constraints, and testing criteria.

2. Pick **one step** from the ticket's step list to work on. Do not work on multiple steps simultaneously.

3. Implement the step.

4. Mark the step as done:

```bash
vtb step-done <ticket-id> <step-index>
```

`<step-index>` is 1-based.

## Testing

After completing a step, write tests to validate the new behavior:

- Add unit, property, or integration tests as appropriate for the change.
- Use strong assertions against concrete test data. Avoid loose checks like `assert result` when you can assert `assert result.name == "expected_name"`.
- Run the full test suite and ensure all tests pass before committing:

```bash
mix test
```

## Completing a Ticket

1. When all steps in a ticket are done, advance it through the workflow:

```bash
vtb workflow advance <ticket-id>
```

2. Then check the parent ticket. If all of the parent's children are now done, advance the parent to done as well. Recurse upward.

3. After completing a ticket, return to **Finding Work** to pick the next one.

## Summary

```
find in_progress ticket
  └─ recurse into deepest in_progress child
      └─ pick one step, implement it
          └─ write tests, run `mix test`
              └─ `vtb step-done <id> <index>`
                  └─ all steps done? → `vtb workflow advance <id>`
                      └─ all sibling tickets done? → advance parent
                          └─ repeat
```
