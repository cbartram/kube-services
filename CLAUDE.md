# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of hand-written Helm charts (`manifests/<service>/`) for a single home Kubernetes cluster. There is no application code, no build, and no test suite — the deliverable is YAML. ArgoCD watches this repo and syncs the charts to the cluster, so a merged change is a deploy.

Base CRDs are **not** installed by these charts. The cluster is expected to already have: MetalLB, the Tailscale Kubernetes Operator, Gateway API + Istio (the `kraken-gateway`), Longhorn (storage class `longhorn`), and ArgoCD.

## Commands

```bash
helm lint manifests/<chart>                                  # syntax/values check
helm template <name> manifests/<chart>                       # render to stdout — the main way to verify a change
helm upgrade --install <name> manifests/<chart> -n <ns> --create-namespace   # manual apply (ArgoCD normally does this)

kubectl apply -f manifests/argocd/argocd-cmd-params.yaml     # argocd/ and tailscale/ are raw manifests, not charts
kubectl apply -f manifests/tailscale/proxygroup.yaml
```

ArgoCD itself is upgraded by applying upstream manifests directly, not through this repo:

```bash
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/install.yaml
```

## Architecture

### Two exposure patterns

**Public HTTP (Gateway API).** Traffic path is `user → Cloudflare (SSL edge termination) → cloudflared tunnel → kraken-gateway (Istio, port 80) → Service, routed by Host header`. Charts declare an `HTTPRoute` with:

- `parentRefs`: name `kraken-gateway`, namespace `kraken`, `sectionName: http-subdomain`
- `hostnames`: `<service>.kraken-plugins.com`
- timeouts of `3600s` on both `request` and `backendRequest`

Because Cloudflare terminates TLS, routes attach to the **http** listener — do not switch them to an https section. Used by n8n, minio, jellyfin, seaweedfs.

**Private / non-HTTP (Tailscale).** Game servers are exposed only on the tailnet: a `Service` of `type: LoadBalancer` with `loadBalancerClass: tailscale` plus the `tailscale.com/hostname`, `tailscale.com/proxy-group`, and `tailscale.com/expose` annotations, paired with a `ProxyGroup` CRD (`tailscale.com/v1alpha1`, `type: ingress`) rendered by the same chart. No NodePorts, no host networking, no router port forwarding. Used by valheim and vrising.

### Storage

All persistent volumes use the `longhorn` storage class, `ReadWriteOnce`. **Every PVC carries `argocd.argoproj.io/sync-options: Delete=false`** so an ArgoCD prune never destroys data — keep this annotation on any new PVC. Because volumes are RWO, workloads that mount them use `replicas: 1` and `strategy.type: Recreate` (see valheim) so two pods never contend for the same volume.

### Secrets

No chart templates a Secret. Every secret is created out of band with `kubectl create secret` and referenced by name, so credentials stay out of version control. Existing ones a chart will fail without:

| Chart      | Secret                | Keys                                     |
|------------|-----------------------|------------------------------------------|
| cloudflare | `tunnel-credentials`  | `tunnel-token`                           |
| minio      | `minio-secrets`       | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |
| seaweedfs  | `seaweedfs-s3-config` | mounted as `/etc/seaweedfs/s3.json`      |
| valheim    | `valheim-secret`      | `server-password`                        |
| vrising    | `vrising-secret`      | `server-password`                        |

### Chart conventions

These are not `helm create` charts. There is no `_helpers.tpl`, no `NOTES.txt`, and no fullname templating — resource names are written literally or come from `.Values.name`.

- Namespace comes from `.Values.namespace`, **not** `.Release.Namespace` (cloudflare is the one exception). Charts do not create their own namespace; rabbitmq is the only one with a `namespace.yaml` template.
- Structured values (`labels`, `resources`, `nodeSelector`, `tolerations`, `affinity`) are injected with `{{- toYaml … | nindent N }}`.
- Parameterization is inconsistent by design-drift: **jellyfin** is the most fully parameterized chart (its `httpRoute` block lives entirely in `values.yaml`), while minio, n8n, and seaweedfs hardcode hostnames and namespaces in the template. When adding a chart, prefer the jellyfin shape.
- Game-server tuning is done through an `extraEnv` map in `values.yaml` that the deployment ranges over into env vars (`HOST_SETTINGS_*` / `GAME_SETTINGS_*` for vrising, mod flags for valheim). Gameplay changes are values-only edits.

### Notable per-chart details

- **valheim** runs a second container, `cbartram/rekja-sidecar`, sharing both PVCs; it reads `/config/valheimplus/plugins` and uses a downward-API namespace/pod name plus `REKJA_LABEL_SELECTOR` to restart the main container. `mods.bepinex` and `mods.valheimPlus` are mutually exclusive — the image will not start with both true.
- **n8n** stores all state on `n8n-pvc` at `/home/node/.n8n`; an init container chowns it to 1000:1000. `manifests/n8n/workflows/*.json` are backups of the live workflows and are **not** imported by any template — `values.yaml` has a `bootstrap` block that no template currently consumes, so workflows are imported through the N8N UI (see `manifests/n8n/README.md` for the credentials each one needs).
- **seaweedfs** runs master, volume, filer, S3, and WebDAV in a single `weed server` process; its deployment name is taken from `.Values.namespace`.
- **metallb** only supplies the `IPAddressPool` (192.168.0.221–250) and `L2Advertisement`; MetalLB itself must be pre-installed.
- **windrose** is untracked `helm create` scaffolding with no `templates/` directory yet — the values file is entirely upstream boilerplate.
- `manifests/vrising/README.md` is a copy of the valheim README and describes Valheim, not V Rising.
