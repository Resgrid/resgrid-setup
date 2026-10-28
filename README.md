# Resgrid on Kubernetes / k3s (multi-server)

This branch deploys Resgrid to a Kubernetes cluster spread over several servers: a production-grade layout where the stateless Resgrid services can run several replicas, nodes can be drained for maintenance, and the stateful services keep their data on persistent volumes. It uses only `kubectl` (built-in Kustomize), so it works on [k3s](https://k3s.io) out of the box and on any conformant cluster (kubeadm, RKE2, AKS, EKS, GKE, …).

For one server use the [`master`](https://github.com/Resgrid/resgrid-setup/tree/master) branch. Guide with diagrams: <https://docs.resgrid.com/self-hosted/multi>.

```
              Internet / LAN clients (browsers, Responder + Unit apps)
                                  │ HTTPS 443
                     ┌────────────▼────────────┐
                     │ Ingress (Traefik/nginx)  │  rg.* rgapi.* rgevents.*
                     └──┬─────────┬─────────┬───┘
                 web ×N │  api ×N │  events │  (/tts/audio → tts)
                        ▼         ▼         ▼
              worker ×1 (migrations, jobs)   tts   mcp (cluster-internal)
                        │
     ┌──────────────────┼─────────────────────┬──────────────┐
     ▼                  ▼                     ▼              ▼
  db (PostgreSQL)     redis               rabbitmq        rustfs (S3)
  StatefulSet + PVC   StatefulSet + PVC   StatefulSet+PVC StatefulSet + PVC
```

## What gets deployed

Namespace `resgrid`:

| Kind | Name | Notes |
|---|---|---|
| Deployment | `web`, `api` | Stateless; scale with `kubectl scale`. Data-protection keys and the SignalR backplane are in Redis. |
| Deployment | `events` | Keep 1 replica unless your ingress has sticky sessions (SignalR negotiates and connects in two requests). |
| Deployment | `worker` | Exactly 1. Its init container creates the four databases; the worker then creates/migrates the schema (`RESGRID__DODBUPGRADE=true`) and runs scheduled jobs. |
| Deployment | `tts`, `mcp` | Text-to-speech; MCP for AI assistants (no Ingress: the endpoint is unauthenticated). |
| StatefulSet | `db`, `redis`, `rabbitmq`, `rustfs` | One replica each, `ReadWriteOnce` PVCs (20, 2, 5, 20 GiB). |
| Job | `rustfs-init` | Creates the `resgrid-tts` and `resgrid-imports` buckets. |
| Ingress | `resgrid` | Web, API (+ `/tts/audio`) and events hostnames, TLS from Secret `resgrid-ingress-tls`. |
| Secret | `resgrid-env` | Every setting and secret (generated `deploy/generated/resgrid.env`). |
| ConfigMap | `resgrid-ca` | Public certificate of the Resgrid local CA, trusted by every Resgrid pod. |

Optional ([Optional services](#optional-services)): [`deploy/optional/clamav.yaml`](deploy/optional/clamav.yaml) (virus scanning of uploads), [`deploy/optional/tracking.yaml`](deploy/optional/tracking.yaml) (GPS tracker gateway, LoadBalancer TCP/UDP 5004/5023/5027) and [`deploy/optional/relay.yaml`](deploy/optional/relay.yaml) (inbound email, SMTP 25).

Every Resgrid pod has readiness probes (HTTP from the kubelet; the images contain no shell), resource requests/limits, runs as non-root and listens on 8080.

## Requirements

- Kubernetes 1.27+ or k3s, with **at least one `linux/amd64` node** (the published Resgrid images are amd64-only today; see [Architecture](#architecture)).
- A default `ReadWriteOnce` StorageClass (k3s: `local-path`) and an IngressClass (k3s: `traefik`).
- `kubectl` with a context for the cluster, `openssl`, `bash` (Linux, macOS or WSL).
- DNS records for the three hostnames pointing at the ingress address (the k3s node IPs, or your load balancer).
- Capacity: about 2 vCPU / 3 GB RAM requested by the base install; 3 nodes with 4 vCPU / 8 GB each is a sensible production start.

### Building a k3s cluster

On the first server (use real hostnames/IPs):

```bash
curl -sfL https://get.k3s.io | sh -s - server --cluster-init
sudo cat /var/lib/rancher/k3s/server/node-token
```

On each additional server (3 servers give an HA control plane with embedded etcd):

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<first-server>:6443 K3S_TOKEN=<token> sh -s - server
```

Copy `/etc/rancher/k3s/k3s.yaml` to your workstation as `~/.kube/config` (replace `127.0.0.1` with the first server's address), then check:

```bash
kubectl get nodes -o wide
kubectl get storageclass,ingressclass
```

## Install

```bash
git clone --branch multi https://github.com/Resgrid/resgrid-setup.git resgrid-k8s
cd resgrid-k8s
./setup.sh
```

`setup.sh` asks for the three hostnames, the IngressClass and the pod CIDR, then:

1. Writes `deploy/generated/resgrid.env` from `.env.example` with every password, key and the OpenID Connect certificates generated.
2. Creates the Resgrid local CA (`deploy/generated/ca.crt`/`ca.key`) and issues the ingress certificate for the three hostnames from it, or uses your certificate (`RESGRID_TLS_CERT_FILE` / `RESGRID_TLS_KEY_FILE`).
3. Finds the ingress controller's ClusterIP (Traefik or ingress-nginx) and writes `deploy/generated/host-aliases.yaml`, so pods reach the public hostnames through the ingress (the web app gets API tokens from the API's public URL; events and MCP call it too). Override with `RESGRID_INGRESS_IP`.
4. Shows the current `kubectl` context, asks for confirmation (once per context), runs `kubectl apply -k deploy` and waits for the rollout.
5. Walks you through the [optional features](#optional-features) (Records, Search, Chat, ...).

Unattended:

```bash
RESGRID_WEB_HOST=dispatch.example.com \
RESGRID_API_HOST=dispatchapi.example.com \
RESGRID_EVENTS_HOST=dispatchevents.example.com \
RESGRID_INGRESS_CLASS=traefik \
RESGRID_POD_CIDR=10.42.0.0/16 \
RESGRID_TLS_CERT_FILE=/secure/fullchain.pem \
RESGRID_TLS_KEY_FILE=/secure/privkey.pem \
RESGRID_FEATURES=records,search \
RESGRID_APPLY=1 \
./setup.sh
```

`RESGRID_NO_APPLY=1 ./setup.sh` only generates the files; review them with `kubectl kustomize deploy`.

The pod CIDR is the network the ingress controller connects to the pods from; Resgrid only trusts forwarded headers from it. k3s uses `10.42.0.0/16`; check your CNI otherwise.

The first rollout takes 5–15 minutes while the worker creates the schema:

```bash
kubectl -n resgrid get pods -w
kubectl -n resgrid logs -f deployment/worker
```

Then open `https://<web hostname>` and choose **Sign Up** to create your account and department. Afterwards set `RESGRID__SystemBehaviorConfig__AllowSignupWithoutBilling=false` in `deploy/generated/resgrid.env` and run `./setup.sh` so nobody else can create departments.

### Optional features

Resgrid ships several modules behind feature flags that are off on a new server. Setup asks about each one after the first rollout; change them any time with:

```bash
./setup.sh features         # walk through the optional features
./setup.sh features --all   # also offer flags no feature in the catalog covers
```

One question covers everything a feature needs: **Records (RMS)** (13 flags), **Unified search** (index in the RustFS bucket `resgrid-search`; each Resgrid pod gets an `emptyDir` at `/data/search` for scratch space), **Chat**, **Run cards**, **Checklists**, **Deployments**, **Setup wizard and admin guidance**, **Department import and migration**, **Attachment virus scanning** (applies [`deploy/optional/clamav.yaml`](deploy/optional/clamav.yaml): a ClamAV Deployment with a 2 Gi PVC, about 1.5 GB of RAM) and **Text-message commands (Twilio)**. The paid Resgrid add-ons depend on Resgrid's hosted billing and aren't offered.

Flags are switched for every department (SQL through `kubectl exec` into `db-0`) and the Redis flag cache is cleared; settings a feature needs are written to `resgrid.env`, re-applied as the `resgrid-env` Secret, and the deployments restarted. Without questions: `RESGRID_FEATURES=records,search ./setup.sh features` (or `all` / `none`; features not listed are switched off). Later runs of `./setup.sh` only ask about features that are new in that version and switch recorded features (`RESGRID_FEATURES`) fully back on when needed. The catalog is [`features/catalog.ini`](features/catalog.ini), shared by all branches: see [Maintaining the feature list](https://github.com/Resgrid/resgrid-setup#maintaining-the-feature-list).

### Certificates

- **Public/corporate certificate** (recommended for production): pass `RESGRID_TLS_CERT_FILE`/`RESGRID_TLS_KEY_FILE` (one certificate covering all three hostnames, full chain). To use cert-manager instead, let it manage the Secret `resgrid-ingress-tls` and remove that entry from `deploy/kustomization.yaml`.
- **Local CA** (default): install `deploy/generated/ca.crt` as a trusted root on every client (the [master README](https://github.com/Resgrid/resgrid-setup#trusting-the-local-ca-resgrid_tlsinternal) has per-OS steps). The ingress certificate is valid 397 days; renew with `./setup.sh renew-cert`. Android Resgrid apps only trust public certificates.

### Images and registries

Pods pull `resgridllc/*:latest` (`imagePullPolicy: Always`) and hardened infrastructure images from `dhi.io`. Docker Hub rate-limits anonymous pulls and `dhi.io` may require a login; give the namespace pull credentials:

```bash
kubectl -n resgrid create secret docker-registry regcred --docker-server=https://index.docker.io/v1/ --docker-username=<user> --docker-password=<token>
kubectl -n resgrid create secret docker-registry dhi --docker-server=dhi.io --docker-username=<user> --docker-password=<token>
kubectl -n resgrid patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"},{"name":"dhi"}]}'
```

For production, pin versions instead of `latest`: add an `images:` block to `deploy/kustomization.yaml` (`newTag:` per image) so upgrades happen only when you change it.

## Operations

```bash
kubectl -n resgrid get pods,pvc,ingress
kubectl -n resgrid logs -f deployment/api
kubectl -n resgrid scale deployment/web deployment/api --replicas=3
kubectl -n resgrid rollout restart deployment/web
```

Change settings in `deploy/generated/resgrid.env`, then run `./setup.sh` (re-applies the Secret and restarts the deployments).

### Upgrade and repair

```bash
./setup.sh upgrade      # git pull, then the same as ./setup.sh
```

Running `./setup.sh` again is always safe: it never replaces a value you set, never rotates a secret and never deletes data. On an existing install it:

1. backs up `resgrid.env`, adds the settings new versions need (new secrets get random values), fills in required values that are empty and fixes values known to break;
2. recreates generated files that are missing (local CA, ingress certificate, `hosts.env`, `host-aliases.yaml`);
3. applies the manifests (`kubectl apply -k deploy`, plus the optional services listed in `RESGRID_OPTIONAL`), re-running the `rustfs-init` job so new buckets exist, and restarts the deployments so they pull the newest images; the worker migrates the database;
4. restarts StatefulSet pods that never became ready under an older definition (Kubernetes doesn't replace them on its own);
5. asks about optional features that are new in this version and re-applies the ones you turned on.

Back up first. Installs from before October 2026 tracked `.env` in git; `upgrade` keeps it aside during the `git pull` (the settings themselves have always been in `deploy/generated/resgrid.env`).

### Backup and restore

```bash
kubectl -n resgrid exec statefulset/db -- sh -c 'pg_dumpall -U "$POSTGRES_USER" --clean --if-exists' | gzip > resgrid-$(date +%F).sql.gz
```

Also keep `deploy/generated/` (every secret and the CA key) somewhere safe, and snapshot the `data-rustfs-0` PVC with your storage tooling. Restore:

```bash
kubectl -n resgrid scale deployment --all --replicas=0
gunzip -c resgrid-2026-10-27.sql.gz | kubectl -n resgrid exec -i statefulset/db -- sh -c 'psql -q -U "$POSTGRES_USER" -d postgres'
kubectl -n resgrid scale deployment web api events worker tts mcp --replicas=1
```

### Production hardening

The base keeps one replica of each stateful service so it runs anywhere. For high availability:

- **PostgreSQL**: run [CloudNativePG](https://cloudnative-pg.io) (or a managed database) with streaming replicas and scheduled backups, then point the five `*ConnectionString` settings in `resgrid.env` at its read-write service and remove the `db` StatefulSet from `deploy/base/infrastructure.yaml`. Run `deploy/base/create-databases.sh` against it once (the worker's init container does this too).
- **RabbitMQ**: the [RabbitMQ Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview) with 3 nodes; set `RabbitHostname`, `RabbitHostname2`, `RabbitHostname3`. Keep `deprecated_features.permit.transient_nonexcl_queues = true` in its configuration.
- **Redis**: a managed Redis or a Sentinel setup; update `RedisConnectionString`.
- **Object storage**: RustFS in distributed mode or any S3 service; update the `S3*` settings.
- Spread `web`/`api` replicas across nodes, add PodDisruptionBudgets, and use a storage class with replication (Longhorn, Ceph) or cloud volumes.

## Architecture

The published Resgrid images are `linux/amd64` only; the base pins the Resgrid pods to amd64 nodes with [`deploy/base/patches/amd64-only.yaml`](deploy/base/patches/amd64-only.yaml). Infrastructure pods run on any architecture. Once multi-architecture images are published, remove that patch from `deploy/kustomization.yaml` to schedule on ARM64 nodes too.

## Optional services

Optional services are files in [`deploy/optional/`](deploy/optional), listed (comma separated) in `RESGRID_OPTIONAL` in `deploy/generated/resgrid.env`. `./setup.sh` applies every listed file on each run and removes the ones it applied before that you took out of the list; files you applied by hand are left alone. `clamav` is managed by the virus-scanning feature. For the others:

- **GPS trackers**: enable `RESGRID__UnitTrackingConfig__*`, add `tracking` to `RESGRID_OPTIONAL`, run `./setup.sh`.
- **Inbound email**: set the `RESGRID__RELAY__*` department and domain, add `relay` to `RESGRID_OPTIONAL`, run `./setup.sh`.

Both create `LoadBalancer` Services (k3s ServiceLB publishes them on the node IPs). The relay accepts unauthenticated SMTP: firewall port 25.

## Uninstall

`kubectl delete -k deploy` deletes the workloads, Secrets and the namespace, **including the PVCs and their data** with most storage classes. Back up first.

## Files

| Path | Purpose |
|---|---|
| [setup.sh](setup.sh) | Generate configuration and deploy, upgrade and repair (safe to re-run); `upgrade`; `features`; `renew-cert` |
| [features/catalog.ini](features/catalog.ini), [lib/features.sh](lib/features.sh) | Optional features: the catalog and the code that applies it (shared by every branch) |
| [.env.example](.env.example) | Settings template (becomes the `resgrid-env` Secret) |
| [deploy/kustomization.yaml](deploy/kustomization.yaml) | Kustomize entry point |
| [deploy/base/](deploy/base) | Namespace, infrastructure StatefulSets, Resgrid Deployments, Ingress, scripts |
| `deploy/generated/` | Secrets, certificates, host aliases (generated, git-ignored) |
| [deploy/optional/](deploy/optional) | ClamAV, tracker gateway and email relay |

## License

Apache 2.0, see [LICENSE](LICENSE).
