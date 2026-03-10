---
name: init
description: Initialize vertebrae in a project
---

# /init

Initialize vertebrae in the current project. Registers the project with the Sacrum backend and copies embedded skill files.

## Usage

```bash
# First-time setup (requires API token)
vtb init --token <your-api-token>

# With custom Sacrum URL
vtb init --token <your-api-token> --url http://sacrum.example.com:4000

# Re-initialize (update skills, token already saved)
vtb init

# Custom skill target directory
vtb init --skills-target .claude/commands
```

## Options

| Flag | Description |
|------|-------------|
| `--token` | API token for Sacrum authentication (saved to config file) |
| `--url` | Sacrum API base URL (overrides config file value) |
| `--skills-target` | Target directory for skills (default: `.claude/skills/`) |

## What It Does

1. Loads or bootstraps global config at `~/.config/vertebrae/config.toml`
2. Resolves API token (from `--token` flag or existing config)
3. Derives project slug from current directory name
4. Checks if project exists in Sacrum, creates if needed
5. Registers project in global config
6. Copies embedded skill files to target directory

## Output

```
Vertebrae initialized successfully!

  Config file: /Users/you/.config/vertebrae/config.toml
  Project slug: my-project
  Project name: my-project
  Project ID: bb747fd8-5395-486f-bc8b-24ccd1615e18
  Created new Sacrum project
  Copied 32 skill(s) to .claude/skills/
```

## Idempotent

Running `init` multiple times is safe:
- Existing config is preserved
- Skill files are updated/overwritten
- Project is reused if it already exists in Sacrum

## When to Use

- Setting up vertebrae in a new project
- After cloning a project that uses vertebrae
- Updating skill files after vertebrae updates
