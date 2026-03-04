# Project Overview

Sacrum is an API-only Phoenix 1.8 application (Elixir ~> 1.15) with PostgreSQL. There is no browser UI — all endpoints serve JSON via the `:api` and `:api_authenticated` router pipelines. Authentication is bearer token based (API tokens with Argon2 password hashing). It uses Bandit as the HTTP server and Ecto for data access.

## Common Commands

```bash
mix setup                          # Full project setup (deps, DB, assets)
mix phx.server                     # Start dev server at localhost:4000
iex -S mix phx.server              # Start with IEx console
mix test                           # Run all tests (auto-creates/migrates DB)
mix test test/path/to_test.exs     # Run specific test file
mix test --failed                  # Re-run previously failed tests
mix precommit                      # Pre-commit checks: compile (warnings-as-errors), deps check, format, test
mix ecto.gen.migration name        # Generate a new migration (always use this, never create manually)
mix ecto.migrate                   # Run pending migrations
mix ecto.reset                     # Drop, recreate, migrate, and seed DB
mix format                         # Format code
```

The `precommit` alias runs in the `:test` environment (configured in `cli/0`).

## Architecture

### Data Layer (`lib/sacrum/repo/`)

The project uses a repository pattern with dedicated modules instead of Phoenix contexts:

- `Sacrum.Repo` - Ecto repository (PostgreSQL)
- `Sacrum.Repo.Users` - User CRUD operations
- `Sacrum.Repo.ApiTokens` - API token CRUD operations
- `Sacrum.Repo.Schemas.User` - User schema (UUID primary keys, Argon2 password hashing)
- `Sacrum.Repo.Schemas.ApiToken` - API token schema (SHA256 hashed, `sac_` prefixed plaintext)

All schemas use `:binary_id` (UUID) primary keys and `utc_datetime_usec` timestamps.

### Authentication (`lib/sacrum/auth.ex`)

Bearer token auth via `Authorization: Bearer sac_...` header. Tokens are generated with 32 random bytes, prefixed with `sac_`, and only the SHA256 hash is stored. The `SacrumWeb.Plugs.ApiAuthPlug` plug handles extraction and verification, assigning `:current_user` and `:api_token` to the connection.

> **Related:** See [Domain Model](domain-model.md) for GraphQL API details and [Vertebrae Guide](vertebrae-guide.md) for CLI configuration.

### Web Layer (`lib/sacrum_web/`)

- **Router pipelines**: `:browser` (HTML), `:api` (JSON), `:api_authenticated` (JSON + bearer token auth)
- **Controllers**: `SacrumWeb.PageController` (home page)
- **Plugs**: `SacrumWeb.Plugs.ApiAuthPlug` (token auth middleware)

### Test Infrastructure (`test/`)

- `Sacrum.DataCase` - Database tests with SQL sandbox (supports `async: true`)
- `Sacrum.ConnCase` - Controller/plug tests with connection setup
- Tests use `@valid_attrs` module attributes for test data

## Key Conventions

- Use `Req` for HTTP requests (already included). Do not use HTTPoison, Tesla, or httpc.
- Fields set programmatically (e.g., `user_id`) must not appear in `cast` calls; set them explicitly.
- Router `scope` blocks auto-prefix module aliases; don't add redundant aliases.
- Use `Ecto.Changeset.get_field/2` to access changeset fields, not map access syntax on structs.
- Predicate functions end with `?` (not `is_` prefix); reserve `is_` for guards.
- See [phoenix-guidelines.md](phoenix-guidelines.md) for comprehensive Phoenix 1.8, LiveView, HEEx, Ecto, and Tailwind CSS v4 guidelines.

## Related Documentation

| Document | Focus |
|----------|-------|
| [Domain Model](domain-model.md) | GraphQL API, entities, real-time events |
| [Phoenix Guidelines](phoenix-guidelines.md) | LiveView, HEEx, Ecto, Tailwind conventions |
| [Vertebrae Guide](vertebrae-guide.md) | `vtb` CLI for task management |

## Database

Dev credentials: `postgres:postgres@localhost`. Dev DB: `sacrum_dev`, test DB: `sacrum_test`.

Production requires `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST` environment variables.
