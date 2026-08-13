# Releasing

This checklist is for maintainers preparing a GitHub-only release. Spectre
Directive is not published to Hex.

## Prepare the release

1. Confirm `mix.exs` contains the intended version.
2. Move user-visible entries from `Unreleased` into a dated section in
   `CHANGELOG.md`.
3. Confirm installation snippets, supported versions, and roadmap language are
   current.
4. Run the complete validation suite from a clean checkout:

   ```bash
   mix deps.get
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test --cover
   mix credo --strict
   mix dialyzer
   mix docs --warnings-as-errors
   ```

5. Merge the release changes and wait for all GitHub Actions checks on `main`.

## Publish on GitHub

Create and push an annotated tag matching the Mix version:

```bash
git tag -a v0.3.0 -m "Release 0.3.0"
git push origin v0.3.0
```

Create a GitHub Release for that tag using the matching changelog section as
its notes. Verify the source archive, repository documentation, and the
GitHub-tag installation command. Do not run `mix hex.build` or
`mix hex.publish`.

Pushing tags and creating the GitHub release are intentionally manual actions
because they change external state and cannot be fully undone.
