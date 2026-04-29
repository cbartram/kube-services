# N8N Deployments

N8N is configured to persist its runtime state on the `n8n-pvc` Longhorn volume mounted at `/home/node/.n8n`.
That keeps workflows, credentials, and settings across pod restarts and node outages as long as the PVC remains intact.
On first boot, the chart also imports any JSON files in `workflows/` into N8N automatically.

If the PVC is ever lost or corrupted, N8N will come back up empty and workflows need to be re-created from scratch.
Follow the steps below to restore them.

If you update the bundled workflow JSON files and want N8N to import them again, delete the bootstrap marker file
`/home/node/.n8n/.bootstrap-complete` from the PVC and restart the pod.

### Uploading Workflows

Create a new Workflow in N8N, click the 3 dots and upload the workflows from a file. Select the appropriate workflow to upload it.

### Configuring Credentials

For the following workflows:

- `game_update_workflow.json`
- `service_health_monitor.json`

You will need to setup the following credentials:

- Discord Webhook (the webhook for a discord channel the OSRS Game Updates should be posted into)
- SMTP Account (credentials can be retrieved from the Kraken Backend's environment variables)
- Redis Account using: `redis-svc.kraken.svc.cluster.local` host with no user/pass auth

Once credentials are configured make sure to setup the steps that use the services (Discord, Redis, SMTP steps) with the
proper credentials.

### Execution

You can now execute N8N workflows correctly!

