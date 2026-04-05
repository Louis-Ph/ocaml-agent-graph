# Changelog

This project keeps its changelog aligned with Conventional Commits.

- `feat` -> `Added`
- `fix` -> `Fixed`
- `docs` -> `Documentation`
- `refactor`, `test`, `build`, `ci`, `chore` -> `Maintenance`
- commits with `!` or a `BREAKING CHANGE:` footer should be called out under `Breaking`

Until the first tagged release exists, all shipped history is tracked under
`Unreleased`.

## Unreleased

### Maintenance

- add standard GitHub Actions Ubuntu CI with sibling `bulkhead-lm` checkout, build, tests, and demo smoke coverage
- add automated demo-pack coverage tests for catalog consistency and config loading

### Added

- typed multi-agent graph runtime with explicit routing and orchestration (`98a4d07`)
- BulkheadLM-backed LLM runtime integration (`3664d45`)
- procurement-oriented scenario demo packs (`c43bc4e`)
- adaptive webcrawler demo (`982baaa`)
- provider-aware routing aligned with BulkheadLM (`a507243`)
- human and machine terminal clients for graph configuration and execution (`f4cfb44`)
- clone-and-run starter that brings a user directly into the human terminal (`361e540`)
- proactive human terminal assistant with documentation-aware `/docs` and `/wizard` workflows for build, install, cron, SSH, and swarm guidance

### Fixed

- support for new BulkheadLM provider kinds (`739f204`)
- starter idempotence by skipping redundant `bulkhead_lm` pinning when already pinned to the correct sibling checkout (`1eae33a`)

### Documentation

- beginner-friendly usage guides (`25a9e69`)
- linear intent files for OCaml modules (`bc8580d`)
- human terminal assistant playbook tied to the BulkheadLM and ocaml-agent-graph hierarchy
