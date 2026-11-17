# Releasing

This checklist prepares matching source and Hex artifacts. Validate against
Spectre `~> 0.4.0`; use `SPECTRE_PATH` for an explicit local compatibility checkout.
Tagging and publication are separate maintainer actions.

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
   mix credo
   mix dialyzer
   mix docs --warnings-as-errors
   ```

5. Merge the release changes, run CI on the final `main` commit and validate the
   package with `mix hex.publish --dry-run`.

## Publish on GitHub

Create and push an annotated tag matching the Mix version:

```bash
git tag -a VERSION -m "Release VERSION"
git push origin VERSION
```

Create a GitHub Release for that tag using the matching changelog section as
its notes. Verify the source archive, repository documentation, and the
GitHub-tag installation command. Publish the reviewed package with
`mix hex.publish` after its Spectre dependency is available on Hex.

Pushing tags and creating the GitHub release are intentionally manual actions
because they change external state and cannot be fully undone.
