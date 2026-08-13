# Sacrum

Sacrum is an API-only Phoenix/PostgreSQL workflow engine and task-management
backend. It provides authenticated GraphQL operations and realtime project
updates for clients such as the `vtb` CLI and automation daemons.

Use Sacrum to define multi-step workflows, move tasks through those workflows,
track task dependencies and hierarchy, attach structured sections and code
references, and record durable automation execution history.

## Setup

```bash
mix setup
mix phx.server
```

The development server listens on `localhost:4000` by default. All application
endpoints are JSON/API surfaces; Sacrum is not a browser UI.

Useful database commands:

```bash
mix ecto.migrate
mix ecto.reset
```

Development uses `postgres:postgres@localhost` with the `sacrum_dev` database.
Tests use `sacrum_test`.

## Testing

```bash
mix test
mix test test/path/to_test.exs
mix test --failed
mix precommit
```

`mix precommit` runs the standard local checks in the test environment,
including compile, dependency, formatting, and test checks.

## API Surface

Sacrum exposes GraphQL at `/graphql`. In development, GraphiQL is available at
`/graphiql`.

API requests use bearer token authentication:

```text
Authorization: Bearer sac_...
```

The API covers projects, workflows, workflow steps, tasks, sections, code
references, task dependencies, durable `TaskRun` records, step executions, and
session logs. Realtime updates are published through Phoenix channels keyed by
project ID, such as `project:<project_id>`.

## Documentation

| Document | Focus |
| --- | --- |
| [Project Overview](docs/project-overview.md) | Setup, commands, architecture, conventions, and database notes |
| [Domain Model](docs/domain-model.md) | Workflow/task domain, GraphQL API, entities, and realtime events |
| [GUI/CLI TaskRun Contract](docs/client-taskrun-contract.md) | Client-facing TaskRun state and migration guidance |
| [Repository Pattern](docs/patterns.md) | Accounts -> Repo -> Ecto architecture |
| [Testing Guide](docs/testing.md) | Test infrastructure and patterns |
| [Phoenix Guidelines](docs/phoenix-guidelines.md) | Elixir, Ecto, Mix, test, and router conventions |
| [Vertebrae Guide](docs/vertebrae-guide.md) | `vtb` CLI setup and task-management workflows |

## License

Copyright 2026 Rafael Simon Garcia Rodriguez.

Sacrum is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
