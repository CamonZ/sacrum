# Vertebrae (vtb) — CLI Guide

vtb is a CLI client for the Sacrum REST API. Hierarchy: `epic → ticket → task`. Tasks are positioned by **workflow + step**, not standalone status. All commands support `--json`.

## Docs Index

| Document | Read when... |
|----------|-------------|
| [Creating Tasks](vtb/creating-tasks.md) | Adding new epics/tickets/tasks, planning a feature breakdown |
| [Sections & Triage](vtb/sections-and-triage.md) | Documenting a ticket (goal, steps, constraints, tests) or triaging it for work |
| [Workflows & Steps](vtb/workflows-and-steps.md) | Creating or configuring workflows, adding steps, setting up agents/prompts |
| [Navigation](vtb/navigation.md) | Moving tasks through steps, completing work, handling rejections |
| [Dependencies & Refs](vtb/dependencies-and-refs.md) | Linking tasks as blockers, attaching code references |
| [Querying & Updating](vtb/querying-and-updating.md) | Listing/filtering/searching tasks, editing fields, archiving |
| [Execution](vtb/execution.md) | Running steps via daemon, `vtb run-workflow`, execution tracking |
| [Command Reference](vtb/command-reference.md) | Quick lookup of any vtb command |

## Quick Reference

```bash
vtb add "Title" -l ticket -d "Description"   # Create
vtb show <id>                                 # View details
vtb list                                      # Tree view
vtb ready                                     # What needs work
vtb transition-to <id> <step>                 # Move to step
vtb start-step <id>                           # Begin work
vtb complete-step <id>                        # Finish step
```

## Completing a Ticket (Shortcut)

```bash
vtb workflow assign <id> adc4ae7e-6dd6-421b-94b7-50089e911feb
vtb start-step <id>
vtb complete-step <id>
```
