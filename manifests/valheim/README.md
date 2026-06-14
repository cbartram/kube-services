# Valheim Helm Chart

This chart runs a Valheim dedicated server in the namespace configured by `namespace` in `values.yaml`, which defaults to `valheim`, with persistent Longhorn storage and private Tailscale exposure.

## Topology

- `Deployment`: runs one Valheim server pod with a `Recreate` strategy so the ReadWriteOnce volumes are not attached by two pods at the same time.
- `PersistentVolumeClaim`: `valheim-config` is mounted at `/config` for worlds, backups, BepInEx configuration, and mod plugin staging.
- `PersistentVolumeClaim`: `valheim-server` is mounted at `/opt/valheim` so the downloaded dedicated server files survive pod restarts.
- `Service`: exposes UDP `2456`, `2457`, and `2458` as a Tailscale `LoadBalancer` service. No NodePort, host networking, or router port forwarding is used.
- `ProxyGroup`: creates the Tailscale ingress proxy group used by the service annotation.

## Install

Review `values.yaml` first, especially:

- `server.name`
- `server.worldName`
- `server.passwordSecret.name`
- `server.passwordSecret.key`
- `namespace`
- `tailscale.hostname`
- `persistence.storageClassName`

Create the server password Secret before installing or restarting the Deployment. This chart references the Secret but does not render one, so the password is not stored in version control.

```powershell
kubectl create namespace valheim
kubectl -n valheim create secret generic valheim-secret --from-literal=server-password="replace-with-a-password"
```

Valheim requires `SERVER_PASS` to be at least 5 characters unless the server password is disabled through mod configuration.

Install or upgrade the chart:

```powershell
helm upgrade --install valheim .\valheim --namespace valheim --create-namespace
```

Keep `--namespace` aligned with `namespace` in `values.yaml` so Helm stores release state beside the resources it manages.

Check for the Tailscale IP:

```powershell
kubectl -n valheim get service valheim
```

After `EXTERNAL-IP` is populated, connect from a Tailscale device using `valheim.<tailnet>.ts.net:2456` or the shown Tailscale IP.

## Mods

The chart is configured for image-managed ValheimPlus mode with `BEPINEX=false` and `VALHEIM_PLUS=true`. The container image treats those as separate modes and will not start correctly if both are enabled. With ValheimPlus enabled, the container uses:

- `/config/valheimplus/plugins` for additional plugin DLLs and plugin folders
- `/config/valheimplus` for ValheimPlus, BepInEx, and plugin configuration files

Copy your local plugin files into the running pod:

```powershell
$pod = kubectl -n valheim get pod -l app.kubernetes.io/name=valheim -o jsonpath="{.items[0].metadata.name}"
kubectl -n valheim exec $pod -- mkdir -p /config/valheimplus/plugins
kubectl -n valheim cp "E:\SteamLibrary\steamapps\common\Valheim\BepInEx\plugins\." "${pod}:/config/valheimplus/plugins"
kubectl -n valheim cp "E:\SteamLibrary\steamapps\common\Valheim\BepInEx\config\." "${pod}:/config/valheimplus"
kubectl -n valheim rollout restart deployment/valheim
```

If you want plain BepInEx mode instead, set `mods.bepinex=true` and `mods.valheimPlus=false`. In that mode, place plugin files under `/config/bepinex/plugins` and configuration files under `/config/bepinex`.

## Tailscale Notes

The Tailscale Kubernetes Operator must already be installed. The operator must also have permissions for L3 ingress. The service uses:

- `spec.type: LoadBalancer`
- `spec.loadBalancerClass: tailscale`
- `tailscale.com/hostname`
- `tailscale.com/proxy-group`

The chart intentionally does not create NodePorts, use host networking, or expose the service publicly.
