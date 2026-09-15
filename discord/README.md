# Discord plugin

<p align="center">
	<img alt="BunkerWeb Discord diagram" src="https://github.com/bunkerity/bunkerweb-plugins/raw/main/discord/docs/diagram.svg" />
</p>

This [BunkerWeb](https://www.bunkerweb.io/?utm_campaign=self&utm_source=github) plugin will automatically send you attack notifications on a Discord channel of your choice using a webhook.

# Table of contents

- [Discord plugin](#discord-plugin)
- [Table of contents](#table-of-contents)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [Docker](#docker)
  - [Swarm](#swarm)
  - [Kubernetes](#kubernetes)
- [Settings](#settings)
- [TODO](#todo)

# Prerequisites

Please read the [plugins section](https://docs.bunkerweb.io/latest/plugins/?utm_campaign=self&utm_source=github) of the BunkerWeb documentation first.

You will need to setup a Discord webhook URL, you will find more information [here](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks).

# Setup

See the [plugins section](https://docs.bunkerweb.io/latest/plugins/?utm_campaign=self&utm_source=github) of the BunkerWeb documentation for the installation procedure depending on your integration.

There is no additional services to setup besides the plugin itself.

## Docker

```yaml
services:

  bw-scheduler:
    image: bunkerity/bunkerweb-scheduler:1.6.0-rc1
    ...
    environment:
      - USE_DISCORD=yes
      - DISCORD_WEBHOOK_URL=https://discordapp.com/api/webhooks/...
    ...
```

## Swarm

```yaml
services:

  bw-scheduler:
    image: bunkerity/bunkerweb-scheduler:1.6.0-rc1
    ...
    environment:
      - USE_DISCORD=yes
      - DISCORD_WEBHOOK_URL=https://discordapp.com/api/webhooks/...
    ...
    networks:
      - bw-plugins
    ...

networks:
  bw-plugins:
    driver: overlay
    attachable: true
    name: bw-plugins
...
```

## Kubernetes

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress
  annotations:
    bunkerweb.io/USE_DISCORD: "yes"
    bunkerweb.io/DISCORD_WEBHOOK_URL: "https://discordapp.com/api/webhooks/..."
```

# Settings

| Setting                      | Default                                   | Context   | Multiple | Description                                                                                                                                      |
| ---------------------------- | ----------------------------------------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `USE_DISCORD`                | `no`                                      | multisite | no       | Enable sending alerts to a Discord channel.                                                                                                      |
| `DISCORD_WEBHOOK_URL`        | `https://discordapp.com/api/webhooks/...` | global    | no       | Address of the Discord Webhook.                                                                                                                  |
| `DISCORD_RETRY_IF_LIMITED`   | `no`                                      | global    | no       | Retry to send the request if Discord API is rate limiting us (may consume a lot of resources).                                                   |
| `DISCORD_ALERT_IPS`          |                                           | global    | no       | Only notify denied requests from these IPs/networks (separated with spaces, CIDR allowed). Leave empty to notify every denied request.           |
| `DISCORD_UNLISTED_THRESHOLD` | `0`                                       | global    | no       | When `DISCORD_ALERT_IPS` is set, send one summary notification if this many requests from other IPs are denied within `DISCORD_UNLISTED_PERIOD` (`0` to disable). |
| `DISCORD_UNLISTED_PERIOD`    | `600`                                     | global    | no       | Period in seconds used to count denied requests from IPs not in `DISCORD_ALERT_IPS`.                                                             |
| `DISCORD_BAN_ALERT`          | `yes`                                     | global    | no       | Send one escalated notification when a watched IP gets banned, and mute its block alerts while banned.                                          |
| `DISCORD_BAN_MENTION`        |                                           | global    | no       | Optional mention added to the ban notification only (e.g. `@here` or `<@&roleID>`). Leave empty to disable.                                      |
| `DISCORD_FORMAT`               | `default`                    | global    | no       | Message format: `default` or `template`.                                                                                                        |
| `DISCORD_TEMPLATE`             |                              | global    | no       | Custom JSON payload used when `DISCORD_FORMAT=template` (supports `{{variables}}` and `{#if}` sections).                                        |

## Filtering notifications

Receiving every denied request quickly becomes noise. Set `DISCORD_ALERT_IPS` to your own servers (proxies, redirectors, ...) to only get notified when requests coming from them are denied, before BunkerWeb ends up banning one of your own IPs :

```yaml
      - DISCORD_ALERT_IPS=10.0.0.5 10.0.1.0/24
      - DISCORD_UNLISTED_THRESHOLD=100
      - DISCORD_UNLISTED_PERIOD=600
```

With the configuration above, denied requests from `10.0.0.5` and `10.0.1.0/24` are notified immediately. Other denied requests are not notified individually, but a single summary is sent for each IP that gets denied 100 times within 10 minutes.

When `USE_REDIS` is set to `yes`, the counter of denied requests from unlisted IPs is shared between all BunkerWeb instances through Redis. Otherwise each instance counts on its own.

When a watched IP is actually **banned** (added to the ban list, e.g. by bad-behavior), a single escalated notification is sent instead of a block alert, and further block alerts for that IP are muted until the ban ends. Set `DISCORD_BAN_ALERT` to `no` to disable it, and `DISCORD_BAN_MENTION` (e.g. `@here`/`<@&roleID>`) to ping on ban only.

## Message format

`DISCORD_FORMAT` selects how notifications look:

- `default` : the built-in rich embed (no template knowledge required)
- `template` : a fully custom payload from `DISCORD_TEMPLATE`

In `template` mode, `DISCORD_TEMPLATE` is a raw JSON payload that supports `{{variables}}` and `{{#if var}}...{{/if}}` sections. Values are JSON-escaped and the rendered result must be valid JSON; if it isn't, the plugin falls back to the default format and records the error (visible in the web UI). One template covers every event (block / ban / unlisted) via the normalized variables below.

Available variables: `{{ip}}` `{{reason}}` `{{reason_data}}` `{{server_name}}` `{{method}}` `{{uri}}` `{{status}}` `{{user_agent}}` `{{request}}` `{{request_id}}` `{{date}}` `{{headers}}` `{{rule_ids}}` `{{rule_msgs}}` `{{ban_duration}}` `{{count}}` `{{period}}` `{{mention}}` `{{event}}` `{{is_block}}` `{{is_ban}}` `{{is_unlisted}}`

`{{mention}}` is the configured `DISCORD_BAN_MENTION` value and is always available, so you decide where to use it. `{{#if is_ban}}`, `{{#if is_block}}`, `{{#if is_unlisted}}` let one template render differently per event.

Example:

```json
{"content":"{{#if is_ban}}{{mention}} 🚫 {{/if}}IP {{ip}} denied on {{server_name}} (reason={{reason}})"}
```

## Web UI

The plugin page of the web UI shows :

- the IP filter status (`DISCORD_ALERT_IPS`, `DISCORD_UNLISTED_THRESHOLD` and `DISCORD_UNLISTED_PERIOD`)
- the recent webhook delivery results (success/failure, HTTP status, response)
- the IPs/networks of `DISCORD_ALERT_IPS` with their ban status and last notified request
- the IPs not in `DISCORD_ALERT_IPS` that crossed the threshold (one alert per IP per period)
- the watched IPs that got **banned** (one escalated alert per ban, block alerts muted while banned)
- the IPs of `DISCORD_ALERT_IPS` that are currently banned
- the last notified denied requests from IPs of `DISCORD_ALERT_IPS`

Like the other pages of the web UI, the data of all instances is merged (or read from Redis when `USE_REDIS` is set to `yes`).

# TODO

- Add more info in notification :
  - Date
  - Country of IP
  - ASN of IP
  - ...
- Add settings to control what details to send :
  - Anonymize IP
  - Add body
  - Add headers
