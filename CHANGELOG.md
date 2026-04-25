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

### Added

- **one-line installer**: `curl -fsSL .../install.sh | sh` clones the repo, installs git and the OCaml toolchain, and launches the human terminal
- **universal Linux support**: `run.sh` now works on any Linux distro (Debian, Fedora, Arch, Alpine, openSUSE) via auto-detected package manager, not just Ubuntu
- **auto-pull BulkheadLM**: `./run.sh` fetches and fast-forwards the sibling BulkheadLM checkout to `origin/main` on every run, handling dirty trees and diverged branches
- **forced recompilation on BulkheadLM changes**: `opam reinstall bulkhead_lm` is triggered automatically when a new revision is detected, preventing stale library code
- **auto-install git**: if git is missing, the starter installs it via the detected package manager before cloning
- **one-command messenger stack**: `scripts/start-with-messengers.sh` auto-detects connector tokens (Telegram, WhatsApp, Messenger, Instagram, LINE, Viber, WeChat, Discord), generates a BulkheadLM gateway config, starts both servers, and opens the terminal
- **default local switch creation**: opam switch prompt now defaults to Y instead of N
- typed multi-agent graph runtime with explicit routing and orchestration (`98a4d07`)
- BulkheadLM-backed LLM runtime integration (`3664d45`)
- procurement-oriented scenario demo packs (`c43bc4e`)
- adaptive webcrawler demo (`982baaa`)
- provider-aware routing aligned with BulkheadLM (`a507243`)
- human and machine terminal clients for graph configuration and execution (`f4cfb44`)
- clone-and-run starter that brings a user directly into the human terminal (`361e540`)
- proactive human terminal assistant with documentation-aware `/docs` and `/wizard` workflows for build, install, cron, SSH, and swarm guidance
- multi-agent discussion workflow: structured participant rounds with configurable personas, versioned rules, and a final synthesis agent; budget circuit-breaker stops gracefully on provider 429 (`e7d001c`)
- live discussion streaming in the human terminal: each speaker turn is printed as it arrives (`e7d001c`)
- **L0-L3 typed agentic swarm layers** (`b12906e`):
  - `Core.Envelope` (L0) — typed message envelope with `id`, `correlation_id`, `causation_id`, `schema_version`
  - `Core.Capability` (L0) — permission lattice `Observe ⊑ Speak ⊑ Coordinate ⊑ Audit_write` with time-bounded token expiry
  - `Core.Audit` (L0.5) — append-only MD5-hash-chained audit log; `verify_chain` replays from genesis; tamper of any field breaks every subsequent hash
  - `Orchestration.Consensus` (L1) — quorum-based parallel coordination: `⌈n/2⌉+1` votes required, winner by maximum confidence score
  - `Orchestration.Pipeline` (L2) — composable `step` sequence with optional guard predicates; halts immediately on error payload
  - `Core.Pattern` (L3) — stability classes `Frozen/Stable/Fluid/Volatile`; fitness = `success_rate × avg_confidence / (avg_latency_s + 1.0)`
- **`/decide` verifiable decision command** (`e3526a6`): wires L0-L3 end-to-end — opens audit chain, wraps topic in envelope, runs discussion, gates through L1 quorum consensus, validates winner via L2 pipeline, records L3 pattern fitness, seals and verifies chain, archives to `var/decisions/`; supports `--rounds N` and `--pattern ID` inline options
- **`/napoleon` evolutionary swarm command**: runs a configurable Napoleon-pattern swarm from the human terminal with staff planning, parallel scout/corps/critic roles, reserve arbitration across generations, marshal synthesis, L0.5 audit chain, L3 fitness, runtime logs, and archives under `var/napoleon/`
- `Core.Payload.is_error` and `Core.Payload.is_discussion` predicate helpers

### Fixed

- **route readiness startup noise**: the verbose BulkheadLM backend readiness
  table is hidden by default and available on demand with `/routes`
- **runtime logs in all reports**: `Runtime_logger` now collects every log entry; discussion archives, decision archives, and graph results all include a "Runtime Logs" section with the full execution trace
- **human terminal UX overhaul**: complete visual redesign with Unicode box-drawing frames, color-coded status bar (model, attachments, turn count), framed assistant responses, numbered suggested commands with reasons, and richer welcome banner for a polished first impression
- **discussion prompt overhaul**: redesigned participant prompts to eliminate meta-commentary and transcript parsing; simplified transcript format, strengthened system prompt with strict anti-meta rules, expanded sanitizer filters, increased participant token budget to 600, and reduced default rounds from 5 to 3 to cut token waste while preserving output quality
- support for new BulkheadLM provider kinds (`739f204`)
- starter idempotence by skipping redundant `bulkhead_lm` pinning when already pinned to the correct sibling checkout (`1eae33a`)
- discussion budget circuit-breaker: tri-state `turn_result` (`Turn_produced / Turn_skipped / Turn_budget_exhausted`) stops the run loop cleanly on provider 429 and returns the partial discussion collected so far instead of cascading failures
- startup warning when a configured discussion participant route has zero ready backends
- `max_tokens` for discussion participants raised to 360 in the example config to prevent truncated contributions

### Documentation

- beginner-friendly usage guides (`25a9e69`)
- linear intent files for OCaml modules (`bc8580d`)
- human terminal assistant playbook tied to the BulkheadLM and ocaml-agent-graph hierarchy
- **`docs/swarm-layers.md`** — L0-L3 API reference with usage examples, layer map, and test-run commands

### Maintenance

- add standard GitHub Actions Ubuntu CI with sibling `bulkhead-lm` checkout, build, tests, and demo smoke coverage
- add automated demo-pack coverage tests for catalog consistency and config loading
- **`test/test_protocol.ml`** — 27 Alcotest cases covering L0 envelope provenance chain, capability lattice order, L0.5 audit chain integrity, tamper detection, and L3 pattern fitness and stability mutation rules
- **`test/test_coordination.ml`** — 8 Alcotest cases covering L1 quorum formula, all-succeed, majority-fails, and exact-threshold; L2 two-step flow, guard skip on error, error halt without guard, and empty pipeline identity
