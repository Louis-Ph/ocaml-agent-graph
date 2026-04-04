# Releasing

This repository uses Conventional Commits as the source material for
`CHANGELOG.md`.

## Commit type mapping

- `feat` -> `Added`
- `fix` -> `Fixed`
- `docs` -> `Documentation`
- `refactor`, `test`, `build`, `ci`, `chore` -> `Maintenance`
- `!` or `BREAKING CHANGE:` -> `Breaking`

## Release checklist

1. Make sure merge commits and direct commits follow Conventional Commits.
2. Group the unreleased commit subjects into the sections above.
3. Update `CHANGELOG.md`:
   - move relevant items out of `Unreleased`
   - create a dated version section
   - leave a fresh empty `Unreleased` section at the top
4. Verify package metadata and community docs are still coherent:
   - `README.md`
   - `CONTRIBUTING.md`
   - `SECURITY.md`
   - `SUPPORT.md`
   - `.github/`
5. Run:

```sh
dune build
dune runtest
```

6. Tag and publish the release.

## Notes

- if a change is user-visible and release-relevant, it should appear in `CHANGELOG.md`
- if a change is internal only, keep the commit conventional anyway, but do not force noisy changelog entries
- if a change breaks behavior, compatibility, config shape, or operational assumptions, call it out explicitly as breaking even if the commit type is not `feat`
