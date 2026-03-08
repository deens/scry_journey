# ScryJourney — Agent Instructions

## Overview

ScryJourney is an executable verification framework for Elixir applications. It runs journey cards (JSON feature contracts) and verifies results through checkpoint assertions.

## Part of the Scry Ecosystem

- Workspace: `~/Developer/scry/`
- Scry core (sibling): `~/Developer/scry/scry/`
- ScryWeb (sibling): `~/Developer/scry/scry_web/`
- Shared docs: `~/Developer/scry/docs/`

## Development

```bash
# Run tests
SCRY_PATH=../scry mix test

# Scry is an optional dependency — journeys work without it
mix test
```

## Architecture

- `ScryJourney.Card` — Load/normalize journey card JSON
- `ScryJourney.Runner` — Execute journey and evaluate checkpoints
- `ScryJourney.Checkpoint` — 10+ assertion types for checkpoint evaluation
- `ScryJourney.Report` — Structured result reports

## Journey Card Format

See `docs/journey-format.md` in the workspace root (to be created).

## Origin

Extracted from Anima Journal (`~/Researcher/dev_language/anima/anima_journal/`). The generic card runner, checkpoint evaluator, and report builder come from there. Anima-specific simulation probes stay in Anima Journal.
