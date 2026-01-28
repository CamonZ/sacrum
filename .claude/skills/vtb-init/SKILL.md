---
name: Initialize
description: Initialize vertebrae in a project
user-invocable: true
allowed-tools: ["Bash"]
---

# /init

Initialize vertebrae in the current project. Creates the database directory and copies skill files.

## Usage

```bash
# Standard initialization
vtb init

# Custom skill source/target
vtb init --skills-source custom/skills --skills-target .claude/commands
```

## Options

| Flag | Description |
|------|-------------|
| `--skills-source` | Source directory for skills (default: `skills/`) |
| `--skills-target` | Target directory for skills (default: `.claude/skills/`) |

## What It Does

1. **Creates database directory**: `.vtb/data/` in the project root
2. **Copies skill files**: From source to target directory

## Output

```
Vertebrae initialized successfully!

  Created database directory: /path/to/project/.vtb/data
  Created skills directory: .claude/skills/
  Copied 15 skill files
```

## Idempotent

Running `init` multiple times is safe:
- Existing database directory is preserved
- Skill files are updated/overwritten

## When to Use

- Setting up vertebrae in a new project
- After cloning a project that uses vertebrae
- Updating skill files after vertebrae updates

## Project Structure After Init

```
project/
├── .vtb/
│   └── data/           # SurrealDB database files
├── .claude/
│   └── skills/         # Skill files for Claude Code
│       ├── add.md
│       ├── list.md
│       └── ...
└── ...
```
