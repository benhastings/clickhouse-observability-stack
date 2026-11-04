# Go/no-go checklist

Copy this file into the environment's own repository, one copy per release. An environment is **go** only when all
six gates below hold. Each gate needs a named owner, evidence someone else can open, and the revision to roll back
to if the gate fails after go-live. Fill in the blanks; leave nothing empty.

Read the [tenant acceptance contract](tenant-acceptance.md) first: it says which signals, dashboards and alerts a
namespace-scoped install lacks, so gate 5 and 6 reviewers know what "healthy" looks like.

`make test/acceptance ENV=<env>` proves gates 2 to 5 in the environment and writes a report to attach as their
evidence ([what it checks](tenant-acceptance.md#proving-it-in-the-environment)); `make check/live ENV=<env>` proves
gate 6.

```markdown
# Go/no-go: <environment>, <date>

Revision set: <stack repo URL> @ <commit SHA>; environment repo @ <commit SHA>
Rollback revision: <previous stack SHA and environment SHA>
Decision: GO / NO-GO     Signed off by: <name>

## 1. Secrets and certificate
- [ ] Every credential and the ClickHouse server certificate are in the approved secret system, at the agreed path.
- Owner: <name>
- Evidence: <secret paths, access policy link, `make cluster/preflight ENV=<env>` output>
- Rollback revision: <SHA, and the previous secret version>

## 2. ClickHouse ready
- [ ] ClickHouse is Available, its Service has ready endpoints, and the schema Job completed.
- Owner: <name>
- Evidence: <`make test/acceptance` report: ClickHouse ready, endpoints, schema Job>
- Rollback revision: <SHA>

## 3. Synthetic signals round trip
- [ ] A synthetic trace, log and metric are written by the collector and read back through Cerberus and Grafana.
- Owner: <name>
- Evidence: <`make test/acceptance` report: OTLP, Cerberus and Grafana checks>
- Rollback revision: <SHA>

## 4. Native traffic is TLS only
- [ ] Native ClickHouse traffic is TLS only, with verified certificates on every client (collector, Cerberus, garmr, garmr sql-adapter, schema Job).
- Owner: <name>
- Evidence: <`make test/acceptance` report (no plaintext port on the Service), each client's verified-TLS setting; `make test/e2e ENV=standalone` proves the clients refuse another CA or name>
- Rollback revision: <SHA>

## 5. Applications healthy, nothing forbidden
- [ ] Every child Application is Synced and Healthy, and none attempts forbidden cluster-scoped work.
- [ ] The degraded signals in the tenant acceptance contract are accepted, with a replacement for `CollectorMemoryNearLimit` if one is needed.
- Owner: <name>
- Evidence: <`make test/acceptance` report (Applications, workloads, quota), `make check/restricted` result, Argo CD denial events (none)>
- Rollback revision: <SHA>

## 6. Revision set
- [ ] The exact revision set is recorded, rendered, and tested against the environment's controls.
- Owner: <name>
- Evidence: <`make check/live` result, the revisions in the `make test/acceptance` report, the rendered manifests, the controls test result>
- Rollback revision: <SHA>
```

## Gates

| # | Gate | Owner | Evidence | Target |
| --- | --- | --- | --- | --- |
| 1 | Credentials and ClickHouse certificate in the approved secret system | environment | secret paths, preflight | none |
| 2 | ClickHouse Available, endpoints ready, schema Job complete | environment | acceptance report | `make test/acceptance` |
| 3 | Synthetic trace, log and metric written and read back | environment | acceptance report | `make test/acceptance` |
| 4 | Native traffic TLS only, certificates verified | environment, ClickHouse owner | client settings, report | `make test/acceptance` |
| 5 | Applications Synced and Healthy, no cluster-scoped work | environment | acceptance report, `make check/restricted` | `make test/acceptance` |
| 6 | Revision set recorded, rendered and tested | environment | live revision check | `make check/live` |

A gate that fails on the day is a no-go, not a note. Roll back to the recorded revision, then rerun from the
failed gate.
