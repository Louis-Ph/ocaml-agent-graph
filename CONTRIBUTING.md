# Contributing to ocaml-agent-graph

Thanks for improving `ocaml-agent-graph`.

This repository favors explicit hierarchy, typed boundaries, externalized
configuration, and test-backed behavior. Contributions are welcome when they
preserve those properties instead of hiding control flow behind convenience
wrappers.

## License

- this repository is licensed under Apache-2.0
- by intentionally submitting a contribution for inclusion in this repository, you agree that it may be distributed under the Apache License 2.0, consistent with Section 5 of [LICENSE](LICENSE)
- if you contribute on behalf of an employer or another rights holder, make sure you are authorized to do so before opening the pull request

## Before you start

- open an issue before large features, new agent families, major refactors, or major public API changes
- keep changes narrow, reviewable, and well-scoped
- do not weaken explicit routing, explicit provider access, or bounded local operations without a documented reason

## Development setup

The simplest local path is:

```sh
./run.sh --help
```

For a fully manual path:

```sh
opam pin add aegis_lm ../aegis-lm --yes --no-action
opam install . --deps-only --with-test --yes
dune build
dune runtest
```

## Design expectations

- preserve the module hierarchy under `lib/core`, `lib/config`, `lib/llm`, `lib/agents`, `lib/runtime`, `lib/orchestration`, `lib/client`, and `lib/web_crawler`
- prefer explicit types, explicit module boundaries, and explicit runtime wiring
- do not scatter magic numbers, route names, prompts, or externally visible strings when a shared definition or config entry is warranted
- keep graph execution behavior auditable through configuration, logs, and tests
- keep starter scripts thin wrappers around the OCaml client instead of moving product logic into shell

## Tests and documentation

- behavior changes should include or update tests in `test/`
- public-facing behavior changes should update `README.md` and the relevant docs
- community-facing changes should keep `CHANGELOG.md`, issue templates, and policy files coherent

## Conventional Commits

Conventional Commits are required for mergeable changes.

Examples:

- `feat: add scenario-scoped agent registry`
- `fix: validate route_model bindings before terminal startup`
- `docs: clarify starter workflow`
- `refactor: split client runtime loading`

Breaking changes should use either:

- `feat!: ...`
- a `BREAKING CHANGE:` footer in the commit body

## Changelog policy

`CHANGELOG.md` is organized from Conventional Commit subjects:

- `feat` entries go under `Added`
- `fix` entries go under `Fixed`
- `docs` entries go under `Documentation`
- `refactor`, `test`, `build`, `ci`, and `chore` entries go under `Maintenance`

Before cutting a release, group the accumulated commit subjects into those
sections and call out any breaking changes explicitly.

## Pull requests

- describe the user-visible effect of the change
- call out graph routing, local execution, starter, or provider-access impacts explicitly
- list the tests and smoke checks you ran
- keep diffs reviewable and intentionally scoped

## Security issues

Do not open public issues for vulnerabilities. Follow [SECURITY.md](SECURITY.md).

## Maintainer review

The maintainer may ask for stronger hierarchy, clearer factorization,
externalized configuration, better tests, or tighter documentation before
merge.
