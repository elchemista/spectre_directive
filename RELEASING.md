# Releasing

This checklist is for maintainers preparing a Hex and GitHub release.

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
   mix hex.publish --dry-run
   ```

5. Inspect the exact archive contents if package metadata changed:

   ```bash
   mix hex.build --unpack
   ```

6. Merge the release changes and wait for all GitHub Actions checks on `main`.

## Publish

Create and push an annotated tag matching the Mix version:

```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

Publish the package and generated documentation from that exact tag:

```bash
mix hex.publish
```

Finally, create a GitHub release for the tag using the matching changelog
section as its notes. Verify the package page, HexDocs landing page, source
links, and installation command.

Publishing, pushing tags, and creating the GitHub release are intentionally
manual actions because they change external state and cannot be fully undone.
