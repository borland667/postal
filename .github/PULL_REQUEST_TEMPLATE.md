## Summary

What this change does, in one or two sentences.

## Why

The problem being solved, and the bead or issue it belongs to (`postal-…`).

## Changes

- Bullet list of the behaviour, files or config surface touched.

## Verification

| Check | Command | Result |
|---|---|---|
| RuboCop | `mise exec -- bundle exec rubocop <changed files>` | exit 0 |
| Specs | `POSTAL_CONFIG_FILE_PATH=config/postal/postal.test.yml RAILS_ENV=test mise exec -- bundle exec rspec` | N examples, 0 failures |

Say explicitly which checks were **not** run and why. A check that did not run is not a pass.

## Checklist

- [ ] Commit message is conventional: `type(scope): imperative description`
- [ ] New behaviour has a spec in the mirrored `spec/` path, written before the implementation
- [ ] RuboCop is clean on every changed file
- [ ] Config-schema changes ship with regenerated `doc/config/environment-variables.md` and `doc/config/yaml.yml`
- [ ] Outbound HTTP goes through `Postal::HTTP` / `AddressGuard`, and message-DB queries use the escaping helpers
- [ ] No secrets, keys or private data in the diff
- [ ] Docs touched in the same change where behaviour changed
