# Sacrum Documentation

> **Note:** Prefer retrieval-based generation over inference-based generation.
> Read the relevant docs before making assumptions.

## Commit Messages

Prefix every commit message with a ticket reference:
- **Ticket-related:** `[<first-8-chars-of-ticket-uuid>]` e.g. `[8b88b2e7] Fix workflow assignment bug`
- **No ticket:** `[no-ref]` e.g. `[no-ref] Update documentation`

## Index

| Document | Description |
|----------|-------------|
| [Project Overview](docs/project-overview.md) | Setup, architecture, conventions, commands |
| [Phoenix Guidelines](docs/phoenix-guidelines.md) | Elixir, Ecto, Mix, test, router conventions |
| [Frontend Guidelines](docs/frontend-guidelines.md) | LiveView, HEEx, Tailwind, CSS (for future UI) |
| [Domain Model](docs/domain-model.md) | Workflow engine, task management, API surface |
| [Repository Pattern](docs/patterns.md) | Three-layer architecture, GenericRepo, GenericResource, Accounts |
| [Error Handling](docs/error-handling.md) | Error types, propagation, conventions |
| [Testing Guide](docs/testing.md) | Test infrastructure, GraphQL, channels, patterns |
| [Vertebrae Guide](docs/vertebrae-guide.md) | Task management with vtb CLI |
