# N8N Deployments

Sometimes the N8N PVC can become wiped or corrupted and N8N workflows needs to be re-created from scratch. Follow
the steps below to recreate them.

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

