# Resgrid on Kubernetes and k3s

This branch deploys the current Resgrid Core stack to Kubernetes with Kustomize, using the `kubectl apply -k` support already built into kubectl. It works with k3s defaults and can be adapted to standard Kubernetes distributions without installing Helm.

The base includes:

- Web, API, events, worker/database migrations, TTS, and MCP Deployments.
- PostgreSQL, Redis, RabbitMQ, and RustFS StatefulSets with persistent volume claims.
- An idempotent RustFS bucket initialization Job.
- A standard `networking.k8s.io/v1` Ingress for web, API/TTS playback, and events.
- Optional tracker-gateway and email-relay manifests.

This is an easy starting topology, not a complete HA production design. Each stateful dependency has one replica. Production operators should use managed or properly clustered data services, define resource requests/limits and disruption budgets, pin images by digest, and implement tested backup/restore procedures.

## Requirements

- Kubernetes 1.27+ or a current k3s release.
- A default `ReadWriteOnce` StorageClass. k3s supplies `local-path` by default.
- An IngressClass. k3s supplies `traefik`; set another class during setup for nginx, HAProxy, or cloud ingress.
- `kubectl`, OpenSSL, and a current kubeconfig context.
- DNS records for three hostnames pointing at the ingress address.
- Registry credentials if your environment requires authentication to pull `dhi.io` images.

### Application image architecture

The current published Resgrid application images contain `linux/amd64` manifests only. The base pins application Deployments to nodes labeled `kubernetes.io/arch=amd64`; infrastructure StatefulSets can run on any architecture supported by their images. A mixed ARM64/AMD64 cluster is supported with at least one AMD64 worker, but a pure Raspberry Pi/ARM64 k3s cluster cannot run the application pods natively today. `setup.sh` checks for an AMD64 node before applying. Do not remove the selector unless you publish and validate native ARM64 Resgrid images or intentionally configure a supported emulation runtime.

For k3s, verify the cluster before starting:

```bash
kubectl get nodes -o wide
kubectl get ingressclass
kubectl get storageclass
kubectl config current-context
```

## Configure and install

```bash
git clone --branch multi https://github.com/Resgrid/resgrid-setup.git resgrid-k8s
cd resgrid-k8s
chmod +x setup.sh
./setup.sh
```

The setup script:

1. Asks for the web, API, and events hostnames, IngressClass, and pod CIDR.
2. Generates unique infrastructure credentials, Resgrid encryption material, and OpenIddict certificates.
3. Generates a self-signed ingress certificate, or uses PEM files supplied through `RESGRID_TLS_CERT_FILE` and `RESGRID_TLS_KEY_FILE`.
4. Builds `deploy/generated/resgrid.env`, `hosts.env`, `tls.crt`, and `tls.key` (all ignored by Git).
5. Shows the active kube context and requires confirmation before `kubectl apply -k deploy`.

Non-interactive example:

```bash
RESGRID_WEB_URL=dispatch.example.com \
RESGRID_API_URL=dispatchapi.example.com \
RESGRID_EVENTS_URL=dispatchevents.example.com \
RESGRID_INGRESS_CLASS=nginx \
RESGRID_POD_CIDR=10.244.0.0/16 \
RESGRID_TLS_CERT_FILE=/secure/fullchain.pem \
RESGRID_TLS_KEY_FILE=/secure/privkey.pem \
RESGRID_APPLY=1 \
./setup.sh
```

Generate and validate without changing a cluster:

```bash
RESGRID_NO_APPLY=1 ./setup.sh
kubectl kustomize deploy >/dev/null
```

The generated `resgrid-env` Secret contains every application environment variable, including database connection strings and OIDC private keys. Back up `deploy/generated/resgrid.env` securely; do not commit it.

## First start

```bash
kubectl -n resgrid get pods -w
kubectl -n resgrid logs -f deployment/worker
kubectl -n resgrid get ingress
```

PostgreSQL creates `resgrid`, `resgridoidc`, `resgridworkers`, and `resgriddoc`; the worker then runs Core schema migrations. Once migration activity settles, open the web hostname and use **Sign Up** to create the first account and department.

If setup generated a self-signed certificate, distribute and trust `deploy/generated/tls.crt` on client devices. The web client must trust the API and events endpoints as well as the web endpoint.

## Private registry credentials

If `dhi.io` requires authentication in your environment, create a registry secret and attach it to the namespace's default ServiceAccount before the pods pull:

```bash
kubectl -n resgrid create secret docker-registry dhi-registry \
  --docker-server=dhi.io \
  --docker-username='YOUR_USER' \
  --docker-password='YOUR_TOKEN'
kubectl -n resgrid patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"dhi-registry"}]}'
```

Use a robot/service credential where supported. Do not put registry passwords in the repository.

## Optional tracker gateway

First configure the `RESGRID__UnitTrackingConfig__*` entries in `deploy/generated/resgrid.env`, then regenerate the Secret by applying the base again and create the optional workload:

```bash
kubectl apply -k deploy
kubectl apply -f deploy/optional/tracking.yaml
kubectl -n resgrid get service tracker-gateway
```

The `LoadBalancer` Service publishes Queclink, GT06, and Teltonika TCP/UDP ports. k3s ServiceLB usually advertises these on node addresses; cloud behavior depends on the provider. Restrict exposure with firewall/network policy controls.

## Optional inbound-email relay

Set the relay department and address-domain values in the generated environment file, re-apply the base Secret, then:

```bash
kubectl apply -k deploy
kubectl apply -f deploy/optional/relay.yaml
kubectl -n resgrid get service relay
```

The relay Service exposes SMTP port 25. The listener has no SMTP authentication or TLS; place it behind a filtering MTA or strict firewall.

## Scaling and customization

Stateless web/API/events workloads can be scaled after validating database and message-bus capacity:

```bash
kubectl -n resgrid scale deployment/web deployment/api deployment/events --replicas=2
```

Keep one worker until you have validated the application's multi-worker behavior and payload-key consistency. TTS and MCP can be scaled independently if their workload and storage paths permit it.

To change default PVC sizes, image tags, probes, or resource limits, add a Kustomize overlay rather than editing generated secrets. The base manifests are under `deploy/base`; generated, host-specific inputs live under `deploy/generated`.

For a generic Kubernetes CNI, set `RESGRID_POD_CIDR` to the actual source network used by your ingress-to-pod traffic. The k3s default is `10.42.0.0/16`; common kubeadm/Calico/Flannel values differ.

## Upgrade and rollback

Before upgrading:

1. Back up `deploy/generated/resgrid.env` and ingress TLS material.
2. Take a PostgreSQL dump and a RustFS volume backup/snapshot.
3. Record deployed image digests: `kubectl -n resgrid get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].imageID}{"\n"}{end}'`.
4. Render and review the candidate: `kubectl kustomize deploy`.

Apply an update with `kubectl apply -k deploy`, then follow worker migrations and rollout status. Do not assume that rolling back Deployments reverses a schema migration.

Rollback requires the previous manifest/image digests plus a compatible pre-upgrade PostgreSQL backup. Restore data first when required, restore the matching generated environment Secret, reapply the previous manifests, and verify worker/API/event logs before reopening ingress traffic.

## Backup example

```bash
kubectl -n resgrid exec statefulset/postgres -- \
  pg_dumpall -U resgrid > "resgrid-$(date +%F).sql"
```

Also back up or snapshot the `data-postgres-0` and `data-rustfs-0` PVCs according to your CSI/storage provider. A raw copy of a live database volume is not a substitute for a consistent dump or storage snapshot.

## Uninstall warning

`kubectl delete -k deploy` removes workloads, Services, Ingress, Secret, and namespace-scoped resources. Persistent volume claim retention depends on Kubernetes and the StatefulSet behavior in your cluster. Never use uninstall as a reset mechanism; inventory and back up PVCs first.
