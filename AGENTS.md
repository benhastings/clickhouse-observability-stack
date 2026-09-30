# `AGENTS.md`

## Purpose

These instructions tell coding agents how to work in this repository. [`CLAUDE.md`](CLAUDE.md) imports this
file, so this is the one place to edit — never write a second copy of a rule somewhere else.

This repository is a GitOps deployment, not an application. An Argo CD app-of-apps deploys an OpenTelemetry
pipeline that stores traces, logs and metrics in ClickHouse, with Cerberus translating Grafana's PromQL, LogQL
and TraceQL into ClickHouse SQL. There is no application code: every file is YAML, a shell script, or docs.
[`README.md`](README.md) is the user-facing guide and the record of design decisions; read its **Design
decisions** section before changing how components fit together.

### Repo map

```text
bootstrap/argocd-values.yaml       Argo CD Helm values: footprint and the custom health checks
bootstrap/repositories.yaml        registers Cerberus's OCI Helm registry with Argo CD
bootstrap/root-app.yaml            the app-of-apps: deploys every Application in apps/
apps/<name>.yaml                   one Argo CD Application per component, with a sync wave
values/<name>.yaml                 Helm values for a chart-based Application of the same name
manifests/<dir>/                   plain manifests an Application deploys by path
scripts/kind-up.sh, kind-down.sh   create and delete the local kind cluster
scripts/port-forward.sh            forward Grafana, Argo CD, Cerberus and OTLP to localhost
scripts/check-apps.bash            enforces the Application conventions below
scripts/check-manifests.bash       renders every chart and validates everything with kubeconform
helm-templates/common/             the library chart every workload is rendered through (see its README)
tests/charts/common-fixture/       an application chart that exercises common, with its helm-unittest suites
kind-config.yaml                   the local cluster definition
git/hooks/                         the pre-commit hook (`make setup/hooks`)
```

## Working in this repository

### Use Makefile targets (always)

Use the existing targets rather than crafting your own shell commands. If an action needs to be repeatable,
add a target. `make help` lists everything.

| Target                      | What it does                                                                 |
| --------------------------- | ---------------------------------------------------------------------------- |
| `make setup`                | installs every check tool (Go, Python 3 and Node required) and the git hooks    |
| `make check`                | the whole gate CI runs: `check/lint` plus `check/manifests`                   |
| `make check/lint`           | offline checks: yamllint, shellcheck, `check/apps`, actionlint, cspell        |
| `make check/apps`           | Application conventions, orphaned files, dashboard JSON                       |
| `make check/manifests`      | `helm template` every chart at its pinned version, then kubeconform the lot   |
| `make test`                 | every offline test; today `test/unit`                                        |
| `make test/unit`            | rebuilds `file://` dependencies, then runs every helm-unittest suite          |
| `make cluster/up`           | kind cluster, Argo CD, root app (~10 min first run, ~3 GB RAM)                |
| `make cluster/port-forward` | Grafana `:3000`, Argo CD `:8080`, Cerberus `:8081`, OTLP `:4317`/`:4318`       |
| `make cluster/down`         | deletes the kind cluster                                                      |

GNU make is required. On macOS use `gmake`, which is what `git/hooks/pre-commit` does.

New targets follow the existing families: `setup/...`, `check/...`, `test/...`, `cluster/...`.

### What the checks enforce

`.github/workflows/check.yml` runs `make check` on every pull request and every push to `main`, and
`make setup/hooks` installs a pre-commit hook that runs `make check/lint`, so nothing here is advisory.

- **YAML** — `yamllint --strict` against `.yamllint.yaml`. Line length is off (dashboard JSON and long
  comments), but indentation, trailing spaces, brace spacing and truthy values are enforced.
- **Shell** — shellcheck on everything in `scripts/` and `git/hooks/`.
- **Application conventions** — `scripts/check-apps.bash`; see the next section.
- **Rendering** — `scripts/check-manifests.bash` runs `helm template` for each chart-based Application with
  the exact repo, version, release name, namespace and values Argo CD would use, against Kubernetes
  `1.34.0`. A values key the chart rejects, or a chart version that no longer exists, fails here.
- **Schemas** — kubeconform in strict mode over the rendered charts, `apps/`, `manifests/` and the bootstrap
  manifests. Core kinds come from the Kubernetes schemas; `Application` and `ClickHouseInstallation` come from
  the [datreeio CRDs catalog](https://github.com/datreeio/CRDs-catalog). A resource with no schema anywhere is
  an error, not a skip.
- **Workflows** — actionlint on `.github/workflows/`.
- **Spelling** — `make check/spelling` runs cspell over every tracked file against `cspell.json`. American and
  British spellings are both accepted. A new proper noun (a chart, a vendor, a tool, a metric name) fails the
  build until it is added to `words` in `cspell.json`, kept sorted; this is the most common way a docs-only
  change goes red.

`make check` proves the manifests are well-formed. It does not prove the stack works: ordering, health,
ClickHouse schema compatibility and Grafana queries are only exercised by deploying to kind.

### Tests

- **A change to `helm-templates/common` needs a helm-unittest case** in
  `tests/charts/common-fixture/tests/`. Turn the feature on in the fixture's `values.yaml` and assert on the
  rendered object.
- **Always run tests through `make test/unit`.** helm-unittest renders the packaged
  `charts/common-<version>.tgz`, not the source directory, so a test run without `make deps` first can pass
  against stale templates. The tarballs are gitignored; `Chart.lock` is committed.
- **Check that a new test can fail.** Break the template it covers, watch it go red, and put the template back.

### Application conventions

`scripts/check-apps.bash` enforces every rule in this list.

- **One Application per file**, `apps/<name>.yaml`, with `metadata.name` equal to `<name>` and
  `metadata.namespace: argocd`.
- **Every Application carries an integer `argocd.argoproj.io/sync-wave`**, the
  `resources-finalizer.argocd.argoproj.io` finalizer, `syncPolicy.automated` with `prune` and `selfHeal`, and
  `destination.server: https://kubernetes.default.svc`.
- **Charts pin an exact version** (`targetRevision: 1.2.3`, never a range or `*`) and are the **first**
  source of a multi-source Application. The second source is this repo with `ref: values`, and value files
  are referenced as `$values/values/<name>.yaml`. A third source of this repo may deploy a `manifests/`
  directory alongside the chart (see `apps/grafana.yaml`).
- **Sources from this repo track `targetRevision: main`**, and their `path` must exist.
- **Nothing is orphaned.** Every `manifests/<dir>` is deployed by some Application, and every
  `values/*.yaml` is used by some Application. Deleting a component means deleting all three.
- **Grafana dashboards are valid JSON** inside their ConfigMap.

The repo URL `https://github.com/benhastings/clickhouse-observability-stack.git` is written into
`bootstrap/root-app.yaml` and every Application. Argo CD deploys from `main` on GitHub, never from your working
tree, so a change is not live on a cluster until it is merged (or until you point `targetRevision` at your
branch on a throwaway cluster — never commit that).

### Sync waves and health

The waves are: operator `0`, ClickHouse `1`, Cerberus `2`, collector and Grafana `3`, demo load `4`. A new
component takes the wave after everything it needs. Waves only mean something because
`bootstrap/argocd-values.yaml` adds two Lua health checks — a child `Application` is healthy only once it is
Synced and Healthy, and a `ClickHouseInstallation` only once the operator reports `Completed`. If you add a
custom resource that later waves depend on, add a health check for it there too.

### Adding or changing a component

1. **Application** — `apps/<name>.yaml`, copying the closest existing one: `apps/otel-collector.yaml` for a
   chart, `apps/clickhouse.yaml` for plain manifests.
2. **Values or manifests** — `values/<name>.yaml` for a chart (start it with a `# Chart: <repo>/<chart>`
   line, as the others do), or `manifests/<name>/` for plain YAML.
3. **Resources** — every container sets a CPU and memory request and a memory limit. The whole stack has to
   fit a laptop (about 2.4 GB measured); say what the new component costs.
4. **README** — update the Components table (chart and version), the sync-wave table, the low-memory sizing
   table, and the layout or troubleshooting sections if they change.
5. `make check`, then deploy to kind (below).

A version bump is the same shape: change `targetRevision` (or the image tag) and the README Components table
in the same commit. Bump one component per PR unless two must move together.

### Coupled versions

- **Cerberus owns the ClickHouse tables.** It runs with `autoCreate.schema: true` and is validated against
  the ClickHouse exporter's v0.152 table layout; the collector's `clickhouse` exporter runs with
  `create_schema: false`. Bumping either the collector image or Cerberus can break inserts or queries without
  any manifest changing, so a bump to either one needs a kind deploy and a query in Grafana, not just
  `make check`.
- **The Altinity operator** changes its CRD surface between minor versions (0.27.4 removed
  `user/k8s_secret_password`). Read its release notes before bumping.
- **telemetrygen** in `manifests/demo-load/` tracks the collector-contrib version.

### Secrets

The ClickHouse password in `manifests/clickhouse/credentials.yaml` and Grafana's `admin`/`admin` are
deliberately public, local-only values and are labeled as such. Never commit any other credential, token or
key, and never replace these with real ones — a real deployment uses a secret manager (the README names
External Secrets and Sealed Secrets).

### Verification before claiming done

- Run `make check` before every push.
- For anything that changes what runs — values, manifests, versions, waves, health checks — deploy it:
  `make cluster/up`, wait for `kubectl -n argocd get applications` to show every app Synced / Healthy, then
  `make cluster/port-forward` and check the result in Grafana. The README's **What you should see** section
  lists the expected demo-load numbers.
- Report exactly what was run. Never write "tested on kind" or "verified in Grafana" in a PR or commit unless
  that happened in this session. `make check` alone is `make check`, and say so.
- If a symptom persists after a fix, check the environment before re-diagnosing: which revision Argo CD
  synced, whether the Application was refreshed, whether an old kind cluster is still running.

### Scope discipline

- **Advice is not a request for edits.** When asked to review, explain or advise, answer in chat and touch no
  files.
- **Build what was asked.** No new components, config knobs or abstractions nobody requested.
- **Ask before a large change** — a new component, a new chart source, or edits across more than ~10 files
  get two or three options with tradeoffs first.
- **Never fork or vendor an upstream chart without approval.** Prefer values, a pinned version, or an
  upstream issue.
- **Keep it laptop-sized.** Production hardening (HA ClickHouse, collector load balancing, real secrets) is
  listed in the README's **Before using this beyond a laptop**; don't fold it into unrelated changes.

### Say it once

YAML invites copy-paste. Before adding a block, check whether the chart already defaults it, and keep values
files to what differs from the chart's defaults.

### Pull request and commit conventions

- **PR titles use conventional commits:** `type: description`, lowercase and imperative —
  `feat: add tempo-compatible trace retention`, `fix: raise cerberus memory limit`,
  `chore: bump otel collector to 0.162.0`, `docs:`, `refactor:`.
- Branch names reflect the change: `feat/<short-description>`, `chore/bump-<component>-<version>`.
- Fill in [the PR template](.github/pull_request_template.md), including which surfaces the change touches and
  whether it was deployed to kind.
- One focused commit per PR.
