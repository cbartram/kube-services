# Windrose Helm Chart

This chart runs a [Windrose](https://github.com/indifferentbroccoli/windrose-server-docker) dedicated server in the namespace configured by `namespace` in `values.yaml`, which defaults to `windrose`, with persistent Longhorn storage and private Tailscale exposure.

The Windrose server binary is Windows only, so the container runs it under Wine on a Linux node.

## Topology

- `Deployment`: runs one Windrose server pod with a `Recreate` strategy so the ReadWriteOnce volume is not attached by two pods at the same time.
- `PersistentVolumeClaim`: `windrose-server` is mounted at `/home/steam/server-files` for the SteamCMD install, world saves, and configuration. 35Gi is the documented minimum for the install alone.
- `Service`: exposes `7777` on both TCP and UDP as a Tailscale `LoadBalancer` service. No NodePort, host networking, or router port forwarding is used.
- `ProxyGroup`: creates the Tailscale ingress proxy group used by the service annotation.

## Connecting

Windrose supports exactly one of two connection methods, and this chart defaults to direct connection so all traffic stays inside the tailnet.

### Direct connection (default)

`server.useDirectConnection: true` sets `USE_DIRECT_CONNECTION=true` and binds the direct connection proxy to `0.0.0.0` so the Tailscale proxy pods can reach it. Players open **Play → Connect to Server** and enter the tailnet address and port:

```
windrose.<tailnet>.ts.net:7777
```

The MagicDNS name only resolves for devices on the tailnet, so the server is unreachable from the public internet. Both TCP and UDP on `7777` are required, which is why the Service publishes the port twice.

### Invite code

Set `server.useDirectConnection: false` and `server.inviteCode` to a string of at least six characters from `0-9 a-z A-Z`. The chart will fail to render if the invite code is missing. In this mode the game's ICE/P2P relay carries the traffic, the server reaches out to the connection service on its own, and the Service and ProxyGroup are not in the connection path at all. Players join with **Play → Connect to Server** using the code.

Optionally set `server.region` to `SEA`, `CIS`, or `EU` to pin the connection service region. Leave it empty to auto select.

## Install

Review `values.yaml` first, especially:

- `server.name`
- `server.maxPlayers`
- `server.useDirectConnection`
- `server.passwordSecret.name` and `server.passwordSecret.key`
- `namespace`
- `tailscale.hostname`
- `persistence.storageClassName`

Create the server password Secret before installing. This chart references the Secret but does not render one, so the password is not stored in version control.

```powershell
kubectl create namespace windrose
kubectl -n windrose create secret generic windrose-secret --from-literal=server-password="replace-with-a-password"
```

Set `server.passwordSecret.enabled: false` to run a passwordless server instead. That is reasonable here because reaching the server already requires being on the tailnet and matching the `tag:windrose` grant.

Install or upgrade the chart:

```powershell
helm upgrade --install windrose .\windrose --namespace windrose --create-namespace
```

Keep `--namespace` aligned with `namespace` in `values.yaml` so Helm stores release state beside the resources it manages.

Check for the Tailscale IP:

```powershell
kubectl -n windrose get service windrose
```

## First start

The container downloads roughly 35Gi through SteamCMD, then starts the server once to generate `ServerDescription.json`, applies the values from the environment, and restarts it normally. Expect the first boot to take a while, and watch it with:

```powershell
kubectl -n windrose logs -f deployment/windrose
```

There are no liveness or readiness probes, matching the other game server charts in this repo. The pod reports ready as soon as the container starts, which is well before the game server is accepting connections.

`server.updateOnStart` defaults to `true`, so every pod restart revalidates the install. Set it to `false` once the world is established to cut startup time.

## Resources

`values.yaml` requests 10Gi of memory with a 12Gi limit and pins 2 CPU cores, which covers the upstream 4 player recommendation with headroom. The upstream sizing guide:

| | 2 Players | 4 Players | 10 Players |
|--|-----------|-----------|------------|
| CPU | 2 cores @ 3.2 GHz | 2 cores @ 3.2 GHz | 2 cores @ 3.2 GHz |
| RAM | 8 GB | 12 GB | 16 GB |
| Storage | 35 GB SSD | 35 GB SSD | 35 GB SSD |

Wine plus SteamCMD makes the install spiky, so the memory limit is set above the request rather than equal to it.

## World settings

World difficulty and multipliers are not environment variables. They live in `WorldDescription.json` on the PVC at:

```
/home/steam/server-files/R5/Saved/SaveProfiles/Default/RocksDB_v2/<version>/Worlds/<world-id>/WorldDescription.json
```

The file can only be edited while the server is stopped, so scale the Deployment down first:

```powershell
kubectl -n windrose scale deployment/windrose --replicas=0
```

Bring up a throwaway pod that mounts the same claim, edit the file, then scale back up. Set `WorldPresetType` to `"Custom"` and fill in `WorldSettings`, for example `WDS.Parameter.MobHealthMultiplier` or `WDS.Parameter.CombatDifficulty`. Set `server.runWorldDescriptionUpdater: true` so `R5WorldDescriptionUpdater.exe` applies the edits on the next start.

`ServerDescription.json` in `/home/steam/server-files/R5/` is regenerated from the chart values on every start while `server.generateSettings` is `true`. Set it to `false` if you want to hand manage that file on the volume instead.

To move an existing world from someone's PC onto this server, see [WORLD-MIGRATION.md](WORLD-MIGRATION.md).

## Windrose+ (optional)

[Windrose+](https://github.com/humangenome/WindrosePlus) adds a web RCON dashboard, a live map, multipliers, and Lua mod support, and it pulls in UE4SS automatically. Set `windrosePlus.enabled: true` and the chart publishes the dashboard on `8780/TCP` through the same Tailscale service. Grant `tcp:8780` on `tag:windrose` in the tailnet policy before using it.

Set `windrosePlus.rconPasswordSecret.enabled: true` with a `rcon-password` key in the Secret to control the dashboard login. That only takes effect on the very first boot, before `windrose_plus.json` exists. After that the password is read live from that file on the PVC.

Leave `windrosePlus.version` empty to track the version baked into the image, or pin a release tag such as `v1.2.3`.

Lua mods go in `/home/steam/server-files/windrose_plus_mods/` on the PVC and load on the next restart.

## Tailscale Notes

The Tailscale Kubernetes Operator must already be installed. The operator must also have permissions for L3 ingress. The service uses:

- `spec.type: LoadBalancer`
- `spec.loadBalancerClass: tailscale`
- `tailscale.com/hostname`
- `tailscale.com/proxy-group`

The tailnet policy needs `tag:windrose` in `tagOwners` and `autoApprovers`, plus a grant from `group:friends` to `tag:windrose` on `tcp:7777` and `udp:7777`. See `../tailscale/policy.hujson`.

The chart intentionally does not create NodePorts, use host networking, or expose the service publicly.
