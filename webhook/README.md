# WebHook plugin

<p align="center">
	<img alt="BunkerWeb WebHook diagram" src="https://github.com/bunkerity/bunkerweb-plugins/raw/main/webhook/docs/diagram.svg" />
</p>

This [BunkerWeb](https://www.bunkerweb.io/?utm_campaign=self&utm_source=github) plugin will automatically send you attack notifications on a custom HTTP endpoint of your choice using a webhook.

# Table of contents

- [WebHook plugin](#webhook-plugin)
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
      - USE_WEBHOOK=yes
      - WEBHOOK_URL=https://api.example.com/bw
    ...
```

## Swarm

```yaml
services:

  bw-scheduler:
    image: bunkerity/bunkerweb-scheduler:1.6.0-rc1
    ..
    environment:
      - USE_WEBHOOK=yes
      - WEBHOOK_URL=https://api.example.com/bw
    ...
```

## Kubernetes

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress
  annotations:
    bunkerweb.io/USE_WEBHOOK: "yes"
    bunkerweb.io/WEBHOOK_URL: "https://api.example.com/bw"
```

# Settings

| Setting                      | Default                      | Context   | Multiple | Description                                                                                                                                      |
| ---------------------------- | ---------------------------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `USE_WEBHOOK`                | `no`                         | multisite | no       | Enable sending alerts to a custom webhook.                                                                                                       |
| `WEBHOOK_URL`                | `https://api.example.com/bw` | global    | no       | Address of the webhook.                                                                                                                          |
| `WEBHOOK_RETRY_IF_LIMITED`   | `no`                         | global    | no       | Retry to send the request if the remote server is rate limiting us (may consume a lot of resources).                                             |
| `WEBHOOK_ALERT_IPS`          |                              | global    | no       | Only notify denied requests from these IPs/networks (separated with spaces, CIDR allowed). Leave empty to notify every denied request.           |
| `WEBHOOK_UNLISTED_THRESHOLD` | `0`                          | global    | no       | When `WEBHOOK_ALERT_IPS` is set, send one summary notification if this many requests from other IPs are denied within `WEBHOOK_UNLISTED_PERIOD` (`0` to disable). |
| `WEBHOOK_UNLISTED_PERIOD`    | `600`                        | global    | no       | Period in seconds used to count denied requests from IPs not in `WEBHOOK_ALERT_IPS`.                                                             |
| `WEBHOOK_BAN_ALERT`          | `yes`                        | global    | no       | Send one escalated notification when a watched IP gets banned, and mute its block alerts while banned.                                          |
| `WEBHOOK_BAN_MENTION`        |                              | global    | no       | Optional mention added to the ban notification only. Leave empty to disable.                                                                     |
| `WEBHOOK_FORMAT`               | `default`                    | global    | no       | Message format: `default`, `blockkit` or `template`.                                                                                            |
| `WEBHOOK_TEMPLATE`             |                              | global    | no       | Custom JSON payload used when `WEBHOOK_FORMAT=template` (supports `{{variables}}` and `{#if}` sections).                                        |

## Filtering notifications

Receiving every denied request quickly becomes noise. Set `WEBHOOK_ALERT_IPS` to your own servers (proxies, redirectors, ...) to only get notified when requests coming from them are denied, before BunkerWeb ends up banning one of your own IPs :

```yaml
      - WEBHOOK_ALERT_IPS=10.0.0.5 10.0.1.0/24
      - WEBHOOK_UNLISTED_THRESHOLD=100
      - WEBHOOK_UNLISTED_PERIOD=600
```

With the configuration above, denied requests from `10.0.0.5` and `10.0.1.0/24` are notified immediately. Other denied requests are not notified individually, but a single summary is sent for each IP that gets denied 100 times within 10 minutes.

When `USE_REDIS` is set to `yes`, the counter of denied requests from unlisted IPs is shared between all BunkerWeb instances through Redis. Otherwise each instance counts on its own.

When a watched IP is actually **banned** (added to the ban list, e.g. by bad-behavior), a single escalated notification is sent instead of a block alert, and further block alerts for that IP are muted until the ban ends. Set `WEBHOOK_BAN_ALERT` to `no` to disable it, and `WEBHOOK_BAN_MENTION` (e.g. a mention string) to ping on ban only.

## Message format

`WEBHOOK_FORMAT` selects how notifications look:

- `default` : the built-in message (no template knowledge required)
- `blockkit` : a predefined rich layout
- `template` : a fully custom payload from `WEBHOOK_TEMPLATE`

In `template` mode, `WEBHOOK_TEMPLATE` is a raw JSON payload that supports `{{variables}}` and `{{#if var}}...{{/if}}` sections. Values are JSON-escaped and the rendered result must be valid JSON; if it isn't, the plugin falls back to the default format and records the error (visible in the web UI). One template covers every event (block / ban / unlisted) via the normalized variables below.

Available variables: `{{ip}}` `{{reason}}` `{{reason_data}}` `{{server_name}}` `{{method}}` `{{uri}}` `{{status}}` `{{user_agent}}` `{{request}}` `{{request_id}}` `{{date}}` `{{headers}}` `{{rule_ids}}` `{{rule_msgs}}` `{{ban_duration}}` `{{count}}` `{{period}}` `{{mention}}` `{{event}}` `{{is_block}}` `{{is_ban}}` `{{is_unlisted}}`

`{{mention}}` is the configured `WEBHOOK_BAN_MENTION` value and is always available, so you decide where to use it. `{{#if is_ban}}`, `{{#if is_block}}`, `{{#if is_unlisted}}` let one template render differently per event.

Example:

```json
{"content":"{{#if is_ban}}{{mention}} 🚫 {{/if}}IP {{ip}} denied on {{server_name}} (reason={{reason}})"}
```

## Web UI

The plugin page of the web UI shows :

- the IP filter status (`WEBHOOK_ALERT_IPS`, `WEBHOOK_UNLISTED_THRESHOLD` and `WEBHOOK_UNLISTED_PERIOD`)
- the recent webhook delivery results (success/failure, HTTP status, response)
- the IPs/networks of `WEBHOOK_ALERT_IPS` with their ban status and last notified request
- the IPs not in `WEBHOOK_ALERT_IPS` that crossed the threshold (one alert per IP per period)
- the watched IPs that got **banned** (one escalated alert per ban, block alerts muted while banned)
- the IPs of `WEBHOOK_ALERT_IPS` that are currently banned
- the last notified denied requests from IPs of `WEBHOOK_ALERT_IPS`

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
