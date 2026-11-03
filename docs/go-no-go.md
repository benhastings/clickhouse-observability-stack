# Go/no-go checklist

Copy this file into the environment's own repository, one copy per release. An environment is **go** only when all
six gates below hold. Each gate needs a named owner, evidence someone else can open, and the revision to roll back
to if the gate fails after go-live. Fill in the blanks; leave nothing empty.

Read the [tenant acceptance contract](tenant-acceptance.md) first: it says which signals, dashboards and alerts a
namespace-scoped install lacks, so gate 5 and 6 reviewers know what "healthy" looks like.

`make test/acceptance` and `make check/live` are planned (#260, #262) and don't exist yet. Until they do, record
the manual evidence named beside them.

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
- Evidence: <`kubectl get chi,endpoints,job` output, schema Job log>
- Rollback revision: <SHA>

## 3. Synthetic signals round trip
- [ ] A synthetic trace, log and metric are written by the collector and read back through Cerberus and Grafana.
- Owner: <name>
- Evidence: <`make test/acceptance` report (planned); until then, the query results from Cerberus and Grafana>
- Rollback revision: <SHA>

## 4. Native traffic is TLS only
- [ ] Native ClickHouse traffic is TLS only, with verified certificates on every client (collector, Cerberus, garmr, garmr sql-adapter, schema Job).
- Owner: <name>
- Evidence: <plain port closed, each client's verified-TLS setting, `make test/acceptance` report (planned)>
- Rollback revision: <SHA>

## 5. Applications healthy, nothing forbidden
- [ ] Every child Application is Synced and Healthy, and none attempts forbidden cluster-scoped work.
- [ ] The degraded signals in the tenant acceptance contract are accepted, with a replacement for `CollectorMemoryNearLimit` if one is needed.
- Owner: <name>
- Evidence: <`argocd app list` output, `make check/restricted` result, Argo CD denial events (none)>
- Rollback revision: <SHA>

## 6. Revision set
- [ ] The exact revision set is recorded, rendered, and tested against the environment's controls.
- Owner: <name>
- Evidence: <`make check/live` result (planned), the rendered manifests, the controls test result>
- Rollback revision: <SHA>
```

## Gates

| # | Gate | Owner | Evidence | Planned target |
| --- | --- | --- | --- | --- |
| 1 | Credentials and ClickHouse certificate in the approved secret system | environment | secret paths, preflight | none |
| 2 | ClickHouse Available, endpoints ready, schema Job complete | environment | cluster objects | none |
| 3 | Synthetic trace, log and metric written and read back | environment | acceptance report | `make test/acceptance` |
| 4 | Native traffic TLS only, certificates verified | environment, ClickHouse owner | client settings, report | `make test/acceptance` |
| 5 | Applications Synced and Healthy, no cluster-scoped work | environment | Argo CD, `make check/restricted` | none |
| 6 | Revision set recorded, rendered and tested | environment | live revision check | `make check/live` |

A gate that fails on the day is a no-go, not a note. Roll back to the recorded revision, then rerun from the
failed gate.
