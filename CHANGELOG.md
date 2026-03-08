# Changelog

## 0.1.0 (2026-03-08)

Initial release of ScryJourney — a verification framework for Elixir applications.

### Added

- **Journey cards** (v1) — declarative `.journey.json` files with checkpoint assertions against MCP tool responses
- **Journey scripts** (v2) — multi-step `.journey.exs` simulation scripts with context threading
- **10 assertion types** — `equals`, `contains`, `matches`, `truthy`, `gte`, `lte`, `integer_gte`, `list_length_gte`, `type_is`, `not_empty`
- **Context threading** — step results flow into subsequent steps via `%{context}` map and `ref()` resolution
- **Step execution** — function and code steps with configurable timeouts and async await
- **Teardown guarantee** — cleanup functions always run, even on step failure
- **Suite runner** — discover and run all `.journey.json` and `.journey.exs` files in a directory
- **Mix task** — `mix scry.journey` for CLI execution with `--transport scry` for MCP-backed runs
- **MCP integration** — `journey_verify` and `journey_run` tools for verification from Claude Code
- **Reports** — per-step and aggregate reports with `schema_version: "journey_script/v2"`
