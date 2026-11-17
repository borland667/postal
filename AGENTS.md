<!-- Repo guide authored from a full architecture review of this checkout on
2026-11-13 (bootstrap seed came from bootstrap-agents.md in the dev-flow skill,
/Users/borland/tools/skills/dev-flow). This file holds this repo's bindings and
verified facts; the workflow process lives in the skill. Update it when the
facts below change. -->
# Agent guide — Postal

Postal is a self-hosted mail server for web applications: it accepts mail over
SMTP and HTTP, queues it, applies per-server policy, and delivers it to
recipients over SMTP/HTTP with DKIM signing, tracking, bounce handling and
spam scanning. Think Sendgrid/Mailgun/Postmark, running on your own servers.

This checkout is a personal fork (`origin` = `git@github.com:borland667/postal.git`)
of [postalserver/postal](https://github.com/postalserver/postal), used to
develop features with the `dev-flow` workflow. Current release line: 3.3.7;
`main` contains unreleased commits after that release.

## Start here

| Document | Read it when |
|---|---|
| [README.md](README.md) | Orientation and links to hosted docs (docs.postalserver.io) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Before any local setup: MySQL dependency, Ruby version, bundler, config file locations |
| [doc/config/configuration.md](doc/config/configuration.md) | Before touching config loading (YAML v2 vs legacy v1, env vars) |
| [doc/config/environment-variables.md](doc/config/environment-variables.md) and [doc/config/yaml.yml](doc/config/yaml.yml) | Generated config reference — **must be regenerated whenever `lib/postal/config_schema.rb` changes** |
| [SECURITY.md](SECURITY.md) | Before changing auth, credentials, DKIM, or delivery trust boundaries; it also states the vulnerability-reporting channel (GitHub security advisories, **not** public issues) |
| `config/routes.rb` | Before adding or changing any HTTP endpoint or scope |

Scope of this guide: the whole repo — the Rails app (`app/`), the core library
(`lib/postal/`), the per-server message store (`lib/postal/message_db/`), the
inbound/outbound SMTP implementations (`app/lib/smtp_server/`,
`app/lib/smtp_client/`), the worker (`app/lib/worker/`), `db/`, `spec/`,
`script/`, `config/`, and the CI/release machinery. Out of scope: the Helm
exporter's target cluster (`lib/postal/helm_config_exporter.rb`), upstream
Postal infrastructure, and production deployment.

## Architecture: what actually runs

Four logical process types, all loading `config/environment.rb` so they share
`Postal::Config`, the logger and the ActiveRecord connection:

| Process | Entry point | Owns |
|---|---|---|
| Web | `config.ru` → Puma (`config/puma.rb`, `Procfile.dev`) | UI, legacy `/api/v1` HTTP API, click/load tracking middleware. Never dequeues mail. |
| Worker | `script/worker.rb` | Dequeue loop and scheduled tasks; the only place mail is actually sent |
| SMTP server | `script/smtp_server.rb` | Inbound SMTP listener (single-threaded nio4r loop) |
| Health | `app/util/health_server.rb` (in-process, WEBrick) | `/health` + Prometheus `/metrics`; started inside the worker and SMTP processes only |

`bin/dev` runs web+worker+smtp through foreman; `bin/postal` is the operator
CLI (`web-server`, `smtp-server`, `worker`, `initialize`, `upgrade`,
`make-user`, `default-dkim-record`, `version`).

**The message path** (this is the spine of the codebase; touch it carefully):

1. **Ingest.** SMTP: `app/lib/smtp_server/server.rb` accepts the socket and
   hands each line to `app/lib/smtp_server/client.rb`, a per-connection state
   machine (`welcome` → `mail_from` → `rcpt_to` → `data` → `finished`) that
   classifies each recipient as bounce / route / credential. HTTP: the legacy
   API (`app/controllers/legacy_api/send_controller.rb`) or the web UI builds a
   message prototype (`app/models/outgoing_message_prototype.rb`).
2. **Insert.** `lib/postal/message_db/message.rb#_create` writes the message
   into the **per-server message DB** and calls `add_to_message_queue`, which
   creates a `QueuedMessage` row in the **main DB**.
3. **Dequeue.** `app/lib/worker/jobs/process_queued_messages_job.rb` atomically
   locks one ready `QueuedMessage` (filtered to IP addresses this host owns)
   and hands the batch to `app/lib/message_dequeuer.rb` → `InitialProcessor` →
   `SingleMessageProcessor`, which dispatches on `message.scope`:
   `incoming` → `IncomingMessageProcessor` (bounce correlation, spam
   inspection, route mode Accept/Hold/Bounce/Reject), `outgoing` →
   `OutgoingMessageProcessor` (content parsing/tracking, suppression list,
   DKIM headers, send limits).
4. **Send.** A sender from `app/senders/` (`SMTPSender`, `HTTPSender`) fulfils
   the `BaseSender` contract (`start`, `send_message`, `finish`). SMTP goes
   through `app/lib/smtp_client/server.rb` → `endpoint.rb` (the only place a
   live `Net::SMTP` session exists), with server order: explicit relays →
   `postal.smtp_relays` → DNS MX records.
5. **Record.** `app/senders/send_result.rb` is the only vocabulary the dequeuer
   understands (`Sent` / `SoftFail` / `HardFail`); soft failures convert to
   `retry_later` via `app/models/concerns/has_locking.rb` (1.3^attempts backoff).
   Events fan out to `WebhookRequest` rows processed by
   `app/lib/worker/jobs/process_webhook_requests_job.rb`.

## Code boundaries — who owns what

- **Two stores, one bridge.** Configuration, identity and ownership live in the
  main MySQL DB (`db/schema.rb`: `organizations`, `users`, `servers`, `domains`,
  `routes`, `credentials`, `ip_pools`, `ip_addresses`, `ip_pool_rules`,
  `track_domains`, `webhooks`, `webhook_events`, `webhook_requests`,
  `queued_messages`, `scheduled_tasks`, `worker_roles`, `statistics`,
  `authie_sessions`, …). Message content and per-message history live in a
  **separate MySQL database per server** named `<prefix>-server-<server_id>`
  (`lib/postal/message_db/database.rb:274`), created on `Server` create and
  dropped on hard destroy (`app/models/server.rb:86-95`): `messages`,
  `deliveries`, `clicks`, `loads`, `links`, `spam_checks`, `suppressions`,
  `webhook_requests`, `live_stats`, `stats_hourly/daily/monthly/yearly`,
  `raw_message_sizes`, and date-partitioned `raw-YYYY-MM-DD` body tables pruned
  by `lib/postal/message_db/provisioner.rb`.
- `Server#message_db` is the **only** door into the message store — controllers,
  jobs, senders and scheduled tasks all go through it. Never construct
  `Postal::MessageDB::Database` directly.
- `QueuedMessage` (main DB) is the handoff object between the two stores; it
  carries lock/retry state, `batch_key`, `ip_address_id` and denormalised
  `domain`/`route_id`. Cross-store references are plain integers with **no
  referential integrity** — resolve them at read time, not with joins.
- **Two migration chains — never conflate them.** Main DB: ordinary ActiveRecord
  migrations in `db/migrate/` (19 files) reflected in `db/schema.rb`. Message
  DB: numbered files `lib/postal/message_db/migrations/NN_name.rb` (20 files)
  with a class named exactly the camellised remainder, inheriting
  `Postal::MessageDB::Migration`, with only an `#up` issuing raw SQL; the runner
  globs the directory, takes the leading number as the version and skips
  versions ≤ each database's `schema_version`. To add one: next zero-padded
  number, exact class name, no `#down`.
- **Adapters wrap external engines, business logic does not.** Spam scanning is
  behind `lib/postal/message_inspector.rb` → `message_inspectors/{clamav,rspamd,spam_assassin}.rb`,
  and inspection failures must **never** fail delivery. DNS goes through
  `app/lib/dns_resolver.rb`. Outbound HTTP goes through `Postal::HTTP`, which
  pins the destination via `lib/postal/http/address_guard.rb` (SSRF guard).
  Mail transport is `app/senders/`. Do not call `Net::HTTP`, `Resolv` or
  `Net::SMTP` directly from controllers or jobs.
- **Config is schema-first.** New options belong in `lib/postal/config_schema.rb`
  (`version: 2`) with type/default/description, plus a legacy mapping in
  `lib/postal/legacy_config_source.rb` if v1 keys must keep working. Precedence
  is env vars > YAML, and `Postal::Config` is built once at require time —
  there is no runtime reload. Env-var names are derived mechanically from
  `GROUP_ATTRIBUTE`, so renaming a group or attribute changes the public
  contract.
- **State ownership rules worth defending:** message status lives in the
  message DB (`messages.status` + deliveries); queue/retry state lives in
  `QueuedMessage`/`WebhookRequest` via `HasLocking`; cluster-wide role locks
  belong only to `WorkerRole`; suppression decisions belong only to the
  message DB's `suppressions` table. DKIM header insertion is centralised in
  `Message#add_outgoing_headers` (idempotent, keyed on `X-Postal-MsgID`) —
  senders must not sign messages.
- Every long-lived process must expose `/health` and `/metrics`
  (`app/util/health_server.rb`) and register metrics via
  `app/util/has_prometheus_metrics.rb`.
- Scheduled work goes in `app/scheduled_tasks/<name>_scheduled_task.rb`
  registered in `Worker::Process::TASKS` (implement `call` + `next_run_after`,
  and make it idempotent — it runs in whichever worker holds the `:tasks` role).
  Continuous draining goes in `app/lib/worker/jobs/`.
- `config/postal/*.yml`, `.env*`, `config/*.key` and `config/*.cert` are local,
  untracked configuration. Never commit real secrets or signing keys.

### Where a new feature goes

| Kind | Location |
|---|---|
| Main-DB model | `app/models/<snake_case>.rb`, subclass `ApplicationRecord` (never `ActiveRecord::Base`), `HasUUID` if user-addressable, validations in the model, shared behaviour in `app/models/concerns/` |
| Message-store entity | `lib/postal/message_db/migrations/NN_*.rb` + a thin wrapper class in `lib/postal/message_db/` (like `Click`, `Delivery`, `SuppressionList`) |
| Controller | `app/controllers/<resource>_controller.rb` including `WithinOrganization`, resolved via `organization.servers` / `find_by_permalink!` / `find_by_uuid!`; respond with `redirect_to_with_json` / `render_form_errors` so one action serves HTML and JSON |
| Views | `app/views/<controller>/*.html.haml` (HAML, not ERB), with `_form`/`_header`/`_nav` partials; helpers in `app/helpers/application_helper.rb` |
| Routes | inside the `scope 'org/:org_permalink', as: 'organization'` block in `config/routes.rb`; public API under `app/controllers/legacy_api/` |
| External side effect | `app/services/<name>_service.rb` (one class per effect) or `app/senders/` for delivery transports |
| Spec | mirror the source path under `spec/` (`spec/models/…`, `spec/lib/postal/…`, `spec/services/…`, `spec/senders/…`, `spec/views/…`) |

### Known weak points — do not make them worse

Duplicated ownership exists in places a new feature can amplify: webhook
attempts are recorded in both `WebhookRequest` (main DB) and the message DB by
`WebhookDeliveryService`, with two different retry policies (`HasLocking#retry_later`
vs a hard-coded `RETRIES` table in `app/services/webhook_delivery_service.rb:5`);
`TrackDomain` reimplements DNS checks instead of using `HasDNSChecks`; endpoint
types (`AddressEndpoint`, `SMTPEndpoint`, `HTTPEndpoint`) each duplicate
`mark_as_used`/`update_routes`; tenant-ownership validation is hand-written
four times; `db/schema.rb` contains a `track_certificates` table with no model
or query; `ApplicationRecord` sets `inheritance_column = 'sti_type'` though no
model uses STI; and message-DB objects resolve columns through `method_missing`,
so a typo yields `nil` rather than an error. Follow the existing pattern where
it exists, and don't add a third copy of a rule that already has an owner.

## Engineering practices

Follow the repo's established conventions (the dev-flow skill's
`engineering-practices.md` supplies the language-independent baseline; these
are the repo-specific bindings).

**Runtime:** Ruby 3.4.6 (`.ruby-version`), Rails 8.1.4.1 (pinned in `Gemfile`),
Bundler 2.7.2 (`Gemfile.lock`), MySQL/MariaDB.

**Style (RuboCop 1.48.1, `.rubocop.yml`)** — the rules that trip newcomers:
- `# frozen_string_literal: true` in every file; double quotes mandatory.
- Empty lines required around class bodies, **none** inside block bodies;
  modules use `empty_lines_except_namespace`.
- Lambdas written `-> (var) { ... }` (space after `->`).
- Symbol arrays as `[:a, :b]`, not `%i[a b]`; word arrays as `%w[...]`, not
  `["a", "b"]`; consistent trailing commas in multiline array literals.
- Line length max 200 (there is a TODO to bring it to 120).
- Prefer assignment inside the condition over ternary assignment; empty methods
  expanded over multiple lines; max 5 parameters (keyword args not counted).
- Deliberately disabled: all `Metrics/*`, `Style/Documentation`,
  `Style/IfUnlessModifier`, `Style/SymbolProc`, `Lint/AssignmentInCondition`,
  `Naming/AccessorMethodName`, `Naming/PredicateName`, `Style/SpecialGlobalVars`,
  `Style/StringConcatenation`, `Layout/FirstHashElementIndentation`.
- Excluded from linting: `bin/*`, `db/schema.rb`, `vendor/bundle/**/*`,
  `lib/tasks/auto_annotate_models.rake`.
- Note: `TargetRubyVersion: 3.0` in `.rubocop.yml` does not match the runtime
  (3.4.6), and `rubocop-rails` is installed but not required by the config.
  Treat both as existing repo facts, not something to "fix" casually.

**Tests (RSpec + factory_bot + shoulda-matchers + webmock + timecop +
database_cleaner-active_record):** 55 spec files.
- Every spec starts with `require "rails_helper"` (there is no `.rspec` file).
- `spec/` mirrors source layout; `infer_spec_type_from_file_location!` means
  request specs must live in `spec/requests` or be tagged `type: :request` —
  otherwise host authorization rejects them (`rails_helper.rb:34`, and the
  `host! Postal::Config.postal.web_hostname` hook at `rails_helper.rb:40-42`).
- `spec/helpers/**` is auto-required: put shared helpers there, not inline.
- Message-DB specs are **not** in-memory: `spec/helpers/message_db_mocking.rb`
  backs every test server with a real MariaDB database
  `postal-test-message-db`, so the test user needs `CREATE DATABASE` rights.
- No real SMTP: senders/clients are stubbed; outbound HTTP is blocked by
  webmock. `verify_partial_doubles` is on, so stubs must match real APIs.
- `spec/lib/dns_resolver_spec.rb` performs **real** DNS lookups of
  `dnstest.postalserver.io` — webmock does not intercept DNS.
- Factories (17 in `spec/factories/`) are linted at suite boot; a broken
  factory fails the whole run before any test executes.

**Docs contract:** `lib/postal/config_schema.rb:7-10` states in-code that schema
changes require `rake postal:generate_config_docs`. Verified 2026-11-13: the
schema declares 113 attributes across 17 groups, and both
`doc/config/environment-variables.md` and `doc/config/yaml.yml` contain exactly
113 entries — they are in sync, and must ship regenerated together with any
schema change in the same commit.

## Local setup and verification

All commands below were run and verified on this host on 2026-11-13.

Ruby is managed with **mise** (`mise use --global ruby@3.4.6`, matching
`.ruby-version`; `mise exec -- gem install bundler:2.7.2` to match
`Gemfile.lock`). A bare `ruby`/`rake`/`rails` in a non-interactive shell resolves
to macOS system Ruby 2.6, so **prefix every repo command with `mise exec --`**
(or put `./bin` first on `PATH`).

```bash
# mysql2's native build needs Homebrew's zstd at link time
LIBRARY_PATH=/opt/homebrew/lib mise exec -- bundle install

# local test database (MariaDB on 3306, empty root password)
docker run -d --name postal-mariadb -p 3306:3306 \
  -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=yes -e MARIADB_DATABASE=postal-test mariadb:11

# per-checkout config + signing key (both gitignored; a fresh worktree needs them)
cp config/examples/test.yml config/postal/postal.test.yml
openssl genrsa -out config/postal/signing.key 2048

# load the schema — db:schema:load, NOT db:migrate (see below)
POSTAL_CONFIG_FILE_PATH=config/postal/postal.test.yml RAILS_ENV=test \
  mise exec -- ruby bin/rails db:create db:schema:load

mise exec -- bundle exec rspec                    # 891 examples, 0 failures, ~1m38s
mise exec -- bundle exec rubocop                    # repo-wide; must exit 0
```

Two traps: `db:migrate` fails because the vendored authie migration
(`db/migrate/20161003195209_create_authie_sessions.authie.rb`) inherits bare
`ActiveRecord::Migration`, which Rails 8 rejects — use `db:schema:load` (the
repo's own `rake postal:update` does the same). And specs that touch DKIM or
signing need `config/postal/signing.key` to exist.

`docker-compose.yml` (`postal` + `mariadb`) is the CI path and requires a
`POSTAL_IMAGE` built from the Dockerfile's `ci` target; the mise + local MariaDB
path is faster day to day and needs no image build.

## Dev flow contract

| Binding | Value |
|---|---|
| Mode | `worktree` — one Git worktree + branch per bead; this primary checkout (`/Users/borland/postal`, `main`) is the integration base |
| Verify (fast) | `mise exec -- bundle exec rubocop` — repo-wide, must exit 0 before any commit (the 20 pre-existing offenses were cleared by `postal-ez6`). Scratch material under `TMP_FILES/` is excluded from linting; everything else in the checkout is linted |
| Verify (full) | `mise exec -- bundle exec rspec` — 891 examples, 0 failures, ~1m38s; needs the local MariaDB container (CI pins MariaDB 11.4). CI runs the same suite in Docker |
| Config docs | Any change to `lib/postal/config_schema.rb` must be followed by `POSTAL_CONFIG_FILE_PATH=config/postal/postal.test.yml mise exec -- bundle exec rake postal:generate_config_docs` and the resulting `doc/config/*` diff committed; CI fails on drift |
| Pull requests | `.github/PULL_REQUEST_TEMPLATE.md` asks for summary, why, changes, a verification table (command / result) and any check that did not run with the reason |
| Task intake | Design: read the relevant `app/` or `lib/postal/` code plus `doc/config/*` for any config-surface change. Diagnose: reproduce with the matching `spec/` file, or exercise the running processes via `bin/dev` / `bin/postal` |
| Test-first | For new behavior, write the spec in the mirrored `spec/` path first, capture red, then implement to green; add newly discovered cases before their fixes |
| Hooks | None installed (no lefthook/overcommit/husky). CI: `.github/workflows/lint.yml` (RuboCop, plus a check that generated `doc/config/*` has no drift) and `.github/workflows/ci.yml` (build Docker image → rspec in container → branch/release image jobs) run on every pull request and on pushes to `main` only; `.github/workflows/close.yml` runs actions/stale daily |
| Deterministic gates | No local gate yet. Adding one (e.g. a pre-commit RuboCop hook) is authorized work under its own bead, not an assumed baseline |
| Integration | Base branch `main`; remote `origin` = `borland667/postal`; upstream changes arrive by merging `postalserver:main` into `main` (the fork keeps no `upstream` remote); one squashed commit per bead; branch names become Docker image tags under the running repo owner (`ghcr.io/<owner>/postal:branch-<ref>`), so name them deliberately. Throwaway CI-verification branches are named `ci-verify-*` and publish no image |
| Base sync | `git fetch origin && git rebase origin/main` in the task worktree before landing |
| Autonomy | `commit-push` — commit and push task branches to `origin`; never merge into `main`, tag, or deploy without separate authorization |
| Coordinator | `none` — solo per task; independent review via a fresh session |
| Local second opinion | Not enabled for this repo |
| Models by role | Follow the dev-flow skill's `model-selection.md` host defaults |
| Engineering | Ruby 3.4.6 / Rails 8.1.4.1; RuboCop + rubocop-rails; architecture boundaries as above; no declared file/module size budget |
| Scratch | `TMP_FILES/` at the task worktree root (add `/TMP_FILES/` to `.gitignore` on first use); `log/` and `tmp/` are already gitignored |
| TMP docs | Owner = the task's builder; categories per the dev-flow `tmp-docs.md`; archive to `TMP_FILES/archive/<category>/` on close; bead links must be repaired before deleting a worktree |
| TMP retention | **Binding grant (owner, 2026-11-16): nothing in `TMP_FILES/` is ever pruned.** No age-based deletion, no bulk cleanup, no deletion of archived or superseded drafts. Archiving is not permission to delete. Before removing a worktree, copy its `TMP_FILES/` content to the retained root (`/Users/borland/postal/TMP_FILES/`) instead of discarding it. This applies only to `TMP_FILES/` — Hermes' own scratch cache (`~/.hermes/cache/scratch`, auto-pruned after 24h idle) is a separate mechanism; never leave a durable artifact there |
| Release gate | release-please (`release-please-config.json`, ruby release type, tags without a `v` prefix) opens/merges the release PR from conventional commits on `main`; `publish-image` publishes `stable`/`<version>` images. **Human-triggered**: never hand-edit `CHANGELOG.md` or `.release-please-manifest.json` |
| Tracker | Beads (primary), stealth-local — `bd init --stealth --prefix postal` (2026-11-13), `.beads/` excluded via `.git/info/exclude`; no external tracker |
| Ticket mapping | Disabled / local-only |

**Worktree hazards (verified):** default ports are fixed — web 5000, worker
health 9090, SMTP health 9091, SMTP 25 (`Procfile.dev` even `unset PORT` for web
and SMTP), so two worktrees running `bin/dev` collide immediately; bind/port
must be overridden via `BIND_ADDRESS`/`PORT`. SMTP on port 25 needs privilege
(the Docker image `setcap`s ruby; a local mise ruby does not). Both worktrees
share the same MariaDB and the same message-DB name prefix (`postal`), so
`db:schema:load` or message-DB provisioning in one worktree mutates the other's
data — use a distinct `MESSAGE_DB_PREFIX` and separate ports when running in
parallel. `config/postal/*`, `.env*`, `config/*.key` and `config/*.cert` are
gitignored, so each new worktree must recreate its config and signing key.

## Git and delivery

- **Conventional commits**, as used throughout history: `type(scope): imperative
  description` — types `feat`, `fix`, `refactor`, `chore`, `docs`, `test`,
  `perf`; scopes seen include `dkim`, `http`, `message-db`, `worker`,
  `legacy-api`, `deps`, `dockerfile`, `auth`, `tracking`, `specs`. Prefer
  `docs` over `doc` — release-please only maps `docs` into the changelog.
  Body explains *why*. Never write `chore(main): release ...` yourself; release
  commits are generated by release-please.
- Audit the staged diff for secrets before committing; update docs in the same
  change (config-schema changes must include regenerated config docs).
- Authorized: edit in the task worktree, commit, push the task branch to
  `origin`. Not authorized: merging into `main`, tagging, deploying. Pushing
  triggers CI, which builds and publishes images — keep that in mind for WIP
  branches.
- No hooks exist, so nothing to bypass; if gates are added later, never use
  `--no-verify` — fix the hook instead.

## Security non-negotiables

- Every outbound HTTP request must go through `Postal::HTTP` /
  `AddressGuard.safe_connect_address` (`lib/postal/http.rb:56`,
  `lib/postal/http/address_guard.rb`) — it blocks private/metadata ranges and
  pins the validated IP to defeat DNS rebinding. Do not add raw `Net::HTTP`
  calls, and do not widen `postal.allowed_request_destinations` in code.
- Any message-DB query must use the existing escaping helpers
  (`escape_identifier`, `escape`) and the whitelisted operators in
  `database.rb#hash_to_sql`.
- Sign with SHA256 (`lib/postal/signer.rb`); SHA1 helpers are legacy only. DKIM
  key rotation uses the `pending_*` fields and only activates after DNS
  verification (`app/models/domain.rb`).
- Auth is session/credential based: Authie sessions with 2FA for the web UI
  (`login_required`, `admin_required`, `require_organization_owner`), API-key
  credentials (`type: 'API'`) for the legacy API. Keep `return_to` redirect
  validation intact.
- CSP keeps `script_src`/`connect_src` to `'self'`; HSTS is intentionally
  delegated to the reverse proxy (`config/initializers/secure_headers.rb`).
  Keep the HTML escaping/sandboxing of rendered message content.
- Trusted proxies are limited to configured values plus loopback; parameter
  logging is filtered; OpenSSL verification stays `peer`.
- Vulnerabilities are reported through GitHub security advisories, not issues.

## Task state and handoff

Beads is live and primary: `bd where` → `/Users/borland/postal/.beads` (prefix
`postal`, embedded Dolt, stealth mode). Use `bd ready --json` at session start,
reuse the existing bead and worktree on resume, and record task type, lane,
acceptance criteria mapped to observable checks, and the applicable
Design/Diagnose phase before implementing.

At Verify, record on the bead: criterion, tested revision, environment, exact
command, observed result, and any check that did **not** run with the reason.
Close with `bd close <id> --reason "..."` only when the requested acceptance is
met; otherwise leave an executable next action.

**Open items at time of writing:** `postal-0lg` (PostgreSQL dialect for the message
DB) and `postal-fah` (DMARC support — the RFC 9989 record parser and its specs are
merged; the domain check and the views are still to do). `postal-4sc` (this guide),
`postal-ez6` (repo-wide RuboCop gate), `postal-ley` (CI gates) and `postal-9pj`
(pull request template) are closed.
