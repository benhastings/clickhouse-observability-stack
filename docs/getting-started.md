# Getting started on a real cluster

<!-- cspell:words Farah clusterroles storageclass -->

This guide takes you from "I have a Kubernetes cluster" to "I can see traces, logs and metrics in Grafana",
one step at a time. It assumes you're comfortable on a Linux command line but new to Kubernetes and to
observability tools. Each step says what it does, why, and what you should see when it worked.

When something doesn't match what this guide says you should see, go to the [runbook](runbook.md).

For a laptop instead of a shared cluster, the README's **Quick start** does all of this with one command on
kind, and it's a good way to see the finished result before you start.

## 1. What you're about to deploy

Your applications send three kinds of data, which together are called **telemetry**:

- **Traces**: the path one request took through your services, with how long each step took. Each step is a
  **span**.
- **Logs**: lines of text the services write, the same as you'd find in `/var/log`, but collected centrally.
- **Metrics**: numbers over time, such as requests per second, CPU or memory.

The stack stores all three in one database and lets you look at them in Grafana:

```text
your apps ──OTLP──▶ OTel Collector ──▶ ClickHouse ◀── Cerberus ◀── Grafana   (you, in a browser)
                         ▲                 ▲
                         │                 └── garmr ◀── vmalert ──▶ Alertmanager   (alerts)
   kubelet, API server ──┘
   (node, pod and cluster metrics)
```

| Piece | What it is, in Linux terms |
|---|---|
| **OTel Collector** | A daemon that listens on ports 4317 and 4318 for telemetry, adds labels, and writes it to the database. Think `rsyslog`, but for all three kinds of data. |
| **ClickHouse** | The database. It's a column store, which makes it fast at "count and group millions of rows". |
| **ClickHouse operator** | A program that runs ClickHouse for you. You hand it a description of the server you want, and it creates the pod, the disk and the config, then keeps them that way. |
| **Cerberus** | A translator. Grafana speaks the query languages of Prometheus (metrics), Loki (logs) and Tempo (traces); Cerberus turns those into SQL for ClickHouse. |
| **Grafana** | The web UI: dashboards, a search page called **Explore**, and the **Drilldown** apps. |
| **vmalert, garmr, Alertmanager** | vmalert checks the alert rules every minute (through garmr, which runs them as SQL), and Alertmanager decides who gets told. |
| **demo-load** | A fake shop (`web`, `checkout`, `payments`) that sends realistic telemetry, so there's something to look at before your own apps are connected. It breaks `payments` on purpose for 10 minutes every hour, so alerts have something to fire on. |

### A few Kubernetes words

If you already know these, skip ahead.

| Word | What it means |
|---|---|
| **Pod** | One or more containers that run together. It's the smallest thing Kubernetes runs. Think of a process with its own filesystem and IP address. |
| **Deployment** | "Keep N copies of this pod running." If a pod dies, the Deployment starts another, like a systemd unit with `Restart=always`. |
| **Namespace** | A folder for objects. This stack uses two: `observability` for nearly everything, and `clickhouse-operator` for the operator. |
| **Service** | A stable name and port in front of pods, such as `grafana:80` or `otel-collector:4318`. Other pods use the name, the way you'd use a hostname in `/etc/hosts`. |
| **Secret** | A small key/value file Kubernetes keeps for you, such as a password, mounted into the pods that need it. Think of a `0600` file in `/etc`. |
| **ConfigMap** | The same, but for non-secret config files. |
| **PersistentVolumeClaim (PVC)** | "I need a 50 GiB disk." The cluster's **StorageClass** decides where that disk comes from (a cloud disk, NFS and so on). ClickHouse keeps its data on one. |
| **Helm chart** | A folder of templated YAML plus default values. `helm install` fills in the values and applies the result, like a package manager whose config files are templates. |
| **Argo CD** | A program in the cluster that keeps the cluster equal to what's in a git branch, like a cron job running `git pull && kubectl apply` that also undoes manual changes. |
| **`kubectl port-forward`** | `ssh -L` for Kubernetes: it opens a port on your machine that tunnels to a Service in the cluster. |

## 2. Check you have what you need

### On your machine

| Tool | Check it with | Why |
|---|---|---|
| `git` | `git --version` | to clone this repository |
| GNU `make` (`gmake` on macOS) | `make --version` | every step is a `make` target |
| `kubectl` | `kubectl version --client` | talks to the cluster |
| `helm` 3 | `helm version` | renders and installs the charts |
| `yq` (Mike Farah's, v4) | `yq --version` | the scripts read the YAML files with it |
| `jq` | `jq --version` | used by the smoke tests in the runbook |
| `curl`, `openssl` | | the same |

`mise use -g kubectl helm yq jq` installs most of them in one go, if you use [mise](https://mise.jdx.dev).

### On the cluster

Point `kubectl` at the cluster, then check each of these:

```bash
kubectl config current-context    # is this the cluster you mean? Everything below acts on it.
kubectl get nodes                 # every node Ready
kubectl version                   # the "Server Version" line
kubectl get storageclass          # at least one; "(default)" next to one is easiest
kubectl auth can-i create customresourcedefinitions   # must say yes
kubectl auth can-i create clusterroles                # must say yes
```

- **Permissions.** You need close to cluster-admin. The install creates a CustomResourceDefinition (a new kind
  of object, `ClickHouseInstallation`), a ClusterRole so the collector can read pod and node information, and
  two namespaces.
- **Kubernetes version.** The stack is tested on 1.37. It only uses long-stable APIs, so older supported
  versions work too, but the preflight check (step 5) stops on any version older than 1.37 unless you tell it
  your version.
- **Room on the nodes.** The example in step 4 requests about 1.5 CPU and 5 GiB of memory, and may use up to
  about 8 GiB. ClickHouse alone takes 4 GiB, so at least one node needs 5 GiB or more free:
  `kubectl describe nodes | grep -A8 'Allocated resources'` shows what's already taken.
- **Disk.** The StorageClass has to be able to provide the size you choose in step 4, 50 GiB in the example.
- **Network.** The nodes need to pull images from `docker.io`, `ghcr.io` and `quay.io`, and Grafana downloads
  its Drilldown apps from `grafana.com` when it starts. Behind a proxy or an air gap, see the runbook's
  **ImagePullBackOff** entry.

## 3. Get the code

```bash
git clone https://github.com/benhastings/clickhouse-observability-stack.git
cd clickhouse-observability-stack
```

Everything that follows runs from this directory.

## 4. Describe your environment

An **environment** is one file of settings for one cluster. The repository ships three: `local` (the kind
laptop cluster), `dev` and `prod`, the last of which is a worked example of production settings. You make your
own instead of editing theirs.

Pick a short name, for example `staging`, and generate the files:

```bash
make env/new NAME=staging
```

That writes two files:

- `cluster-configs/overrides/values-staging.yaml`: your settings. This is the one you edit.
- `cluster-configs/app-of-apps/app-of-apps-staging.yaml`: only used by the Argo CD path in step 6b.

Open `values-staging.yaml` and replace everything after the comments with the example below. Each app starts
from its defaults, which are sized for a laptop; you only write what's different.

```yaml
environment: staging
repoURL: https://github.com/benhastings/clickhouse-observability-stack.git
targetRevision: main
destinationServer: https://kubernetes.default.svc

global:
  labels:
    environment: staging      # added to every object, so `kubectl get pods -l environment=staging` finds them
  mesh: kubernetes            # no Istio. Leave this out only if the cluster runs Istio.

applications:
  clickhouse:
    values:
      clickhouse:
        storage: 50Gi         # the ClickHouse disk. See "Disk sizing" in the README for how to size it.
        lowMemory: false      # turns off the laptop memory tuning
        schema:
          ttlDays:            # how many days of each kind of data to keep; older data is deleted
            traces: 21
            logs: 14
            metrics: 30
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
          limits:
            memory: 4Gi       # the pod is killed if it goes over this, so keep it equal to the request

  cerberus:
    values:
      configMaps:
        env:
          data:
            CERBERUS_PROM_METADATA_LOOKBACK: 30d   # keep equal to ttlDays.metrics above
      deployment:
        containers:
          cerberus:
            env:
              GOMEMLIMIT: 1717986918B              # 80% of the limit, so Go cleans up before it's killed
            resources:
              requests:
                cpu: 250m
                memory: 512Mi
              limits:
                memory: 2Gi

  otel-collector:
    values:
      deployment:
        containers:
          otel-collector:
            env:
              GOMEMLIMIT: 1638MiB                  # 80% of the limit
            resources:
              requests:
                cpu: 250m
                memory: 512Mi
              limits:
                memory: 2Gi
```

The demo load stays on, which is what you want for a first test. To turn it off later, add
`demo-load: {enabled: false}` under `applications`.

The file follows three merge rules: maps merge key by key, `null` deletes a key, and a list replaces the
default list entirely. `cluster-configs/overrides/values-prod.yaml` shows more settings, each with a comment.

To see exactly what will be created, without touching the cluster:

```bash
make helm/template ENV=staging    # writes dist/helm/staging/*-manifests.yaml; open them and look around
```

## 5. Create the passwords, then run preflight

Nothing in this repository contains a password, and the install never makes one up. You create them as
Secrets first. Each ClickHouse user has its own, so a leaked password only reaches what that user may do:

| Secret | Namespace | Used by |
|---|---|---|
| `clickhouse-admin` | `observability` | the job that creates the tables; you, to change things |
| `clickhouse-writer` | `observability` | the collector, which may only insert |
| `clickhouse-reader` | `observability` | Cerberus and garmr's SQL adapter, which may only read |
| `clickhouse-analyst` | `observability` | notebooks and ad hoc SQL, read-only with limits |
| `clickhouse-garmr` | `observability` | garmr, which keeps incidents in its own tables and reads the telemetry |
| `grafana-admin` | `observability` | your Grafana login |
| `clickhouse-operator-credentials` | `clickhouse-operator` | the operator, to manage ClickHouse |

For a test cluster, random passwords are fine:

```bash
pw() { openssl rand -hex 18; }
kubectl create namespace observability
kubectl create namespace clickhouse-operator
for user in admin writer reader analyst garmr; do
  kubectl -n observability create secret generic "clickhouse-$user" \
    --from-literal=username="otel_$user" --from-literal=password="$(pw)"
done
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(pw)"
kubectl -n clickhouse-operator create secret generic clickhouse-operator-credentials \
  --from-literal=username=clickhouse_operator --from-literal=password="$(pw)"
```

The usernames have to be exactly these. On a long-lived cluster, use your secret manager instead (the README's
**Secrets: Kubernetes or Vault** covers External Secrets and Vault).

Now check the cluster against your environment file. Preflight only reads, so it's safe to run as often as
you like:

```bash
make cluster/preflight ENV=staging
```

You want `preflight: all checks passed`. Each `FAIL:` line names one thing to fix: a missing Secret, a
namespace, the StorageClass, Istio. If the only failure is
`Kubernetes 1.xx is older than 1.37.0`, add your version to every command that runs preflight:

```bash
make cluster/preflight ENV=staging KUBE_VERSION=1.33.0    # your server's version from `kubectl version`
```

## 6. Install

There are two ways to install. Use **6a** for a first test: it installs from the files on your machine, so
you can change a value and run it again. Use **6b** when the cluster should follow git from now on.

### 6a. Helm (recommended for a first test)

```bash
make helm/install ENV=staging          # add KUBE_VERSION=... if preflight needed it
```

This runs preflight again, installs the ClickHouse operator and waits for it, then installs everything else
as one Helm release called `stack`. It returns in a minute or two, before everything is running.

To apply a change later, edit `values-staging.yaml` and run the same command again. Helm only changes what
differs.

### 6b. Argo CD (GitOps)

Argo CD reads your environment file from git, not from your machine. Your `values-staging.yaml` and
`app-of-apps-staging.yaml` therefore have to be pushed to a branch Argo CD can read, at the `repoURL` both
files name. For a fork, change `repoURL` in both. Then:

```bash
git checkout -b env/staging
git add cluster-configs/overrides/values-staging.yaml cluster-configs/app-of-apps/app-of-apps-staging.yaml
git commit -m "chore: add the staging environment"
git push -u origin env/staging
make cluster/bootstrap ENV=staging REVISION=env/staging
kubectl -n argocd get applications -w     # wait for every row to say Synced and Healthy
```

`cluster/bootstrap` installs Argo CD if the cluster doesn't have it, creates an Argo CD project for the
environment, and points Argo CD at your branch. From then on, a push to that branch is a deploy. A
`kubectl edit` by hand is undone within minutes, because Argo CD puts back what git says.

## 7. Watch it come up

```bash
kubectl -n observability get pods -w      # Ctrl+C to stop watching
```

Things start in this order. The whole thing takes about 3 to 10 minutes, most of it pulling images:

1. `clickhouse-operator-...` in the `clickhouse-operator` namespace is `Running`.
2. `chi-otel-main-0-0-0` is ClickHouse. It appears once the operator has created it, and gets its disk first,
   so it may sit in `Pending` while the volume is made.
3. `clickhouse-schema-...` is a one-off job that creates the tables. It ends as `Completed`, which is good:
   a job that finished shows `Completed`, not `Running`.
4. `cerberus-...` shows `0/1` until the tables exist, then `1/1`.
5. `otel-collector`, `grafana`, `alertmanager`, `vmalert`, `garmr-sql-adapter`, `garmr` and `demo-load` each reach
   `1/1 Running`.

Done looks like this:

```text
$ kubectl -n observability get pods
NAME                                 READY   STATUS      RESTARTS   AGE
alertmanager-...                     1/1     Running     0          6m
cerberus-...                         1/1     Running     0          6m
chi-otel-main-0-0-0                  1/1     Running     0          5m
clickhouse-schema-...                0/1     Completed   0          5m
demo-load-...                        1/1     Running     0          6m
garmr-...                            1/1     Running     0          6m
garmr-sql-adapter-...                1/1     Running     0          6m
grafana-...                          1/1     Running     0          6m
otel-collector-...                   1/1     Running     0          6m
vmalert-...                          1/1     Running     0          6m

$ kubectl -n observability get chi otel
NAME   STATUS      CLUSTERS   HOSTS   ...
otel   Completed   1          1
```

`RESTARTS` of 1 or 2 early on is normal: the collector and Cerberus can start before ClickHouse is ready, and
may restart while they wait. A number that keeps climbing is not normal; see the runbook.

## 8. Open Grafana

From your machine:

```bash
make cluster/port-forward     # leave it running; Ctrl+C stops it
```

It prints the Grafana password. Open http://localhost:3000 and log in as `admin` with it. The same command
forwards Cerberus to `localhost:8081` and the collector to `localhost:4317`/`4318`, which the runbook's
smoke tests use.

Give the demo load 5 minutes to produce data, then look at:

- **Dashboards → Cerberus → Span metrics (RED)**. RED stands for Rate, Errors, Duration: requests per second,
  the share that fail, and how long they take. `payments` fails about 25% of the time on purpose, and about
  90% during its incident, which runs for 10 minutes starting 15 minutes past each hour. `checkout` stays
  under 5%. Click a line for links to the matching traces and logs.
- **Dashboards → Cerberus → Stack health**: the stack watching itself, with the collector's throughput and
  memory and ClickHouse's inserts. Check here first when data looks wrong.
- **Dashboards → Cerberus → Kubernetes**: the cluster's nodes, namespaces and pods.
- **Explore** (the compass icon): pick a datasource and type a query. Try `{service_name="checkout"}` in
  **Loki (Cerberus)** for logs, or `{status=error}` in **Tempo (Cerberus)** for failing traces.
- **Drilldown** in the left menu: browse metrics, logs and traces without writing queries.

The README's **What you should see** lists every number the demo load should produce.

## 9. Prove it works

Run the runbook's [smoke test](runbook.md#smoke-test-five-minutes). It sends a trace and a log of your own,
reads them back, and checks the alert pipeline. It's the test to repeat after any change.

## 10. Send your own applications' telemetry

Applications instrumented with OpenTelemetry (most languages have an SDK or a zero-code agent) only need to
be told where the collector is. For a pod in the same cluster, set these environment variables:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=my-service      # the name it will have in Grafana
```

Use port 4317 with `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` instead if your SDK prefers gRPC. Within a minute or
two, `my-service` appears in the Span metrics dashboard's service picker and in Explore. To receive
telemetry from outside the cluster, see **Sending your own telemetry** in the README. That needs a hostname
and the collector's bearer-token auth turned on, and the token then applies to every sender, including the
demo load.

## 11. Remove it

With Helm (6a):

```bash
make helm/uninstall ENV=staging
```

That removes the running pieces but leaves your data and passwords, so a reinstall picks up where it left
off. To remove everything, data included:

```bash
kubectl delete namespace observability clickhouse-operator      # deletes the Secrets and the ClickHouse disk
kubectl get crd -o name | grep altinity.com | xargs kubectl delete   # the ClickHouse operator's object kinds
```

With Argo CD (6b), delete the bootstrap Application, which removes every app it created, then the namespaces
as above:

```bash
kubectl -n argocd delete application app-of-apps-staging
```

## Where to go next

- [The runbook](runbook.md): daily checks, the smoke test, what each alert means, and fixes by symptom.
- The README's **Design decisions** explains why each piece is the way it is.
- The README's **Before using this beyond a laptop** lists what to change for production: network policies,
  replicas, multiple nodes, and backups.
- [docs/analysis.md](analysis.md) shows how to read the data from Python for analysis or ML.
