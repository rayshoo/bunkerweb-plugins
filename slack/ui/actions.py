from datetime import datetime, timezone
from ipaddress import ip_address, ip_network
from json import loads
from logging import getLogger
from traceback import format_exc

PLUGIN_ID = "slack"
SETTING_PREFIX = "SLACK"
RECENT_ALERTS_MAX = 20


def _parse_entries(raw):
    entries = []
    for entry in (raw or "").split():
        try:
            entries.append((entry, ip_network(entry, strict=False)))
        except ValueError:
            continue
    return entries


def _parse_networks(raw):
    return [network for _, network in _parse_entries(raw)]


def _in_networks(ip, networks):
    try:
        addr = ip_address(ip)
    except ValueError:
        return False
    return any(addr.version == network.version and addr in network for network in networks)


def _format_date(value):
    try:
        return datetime.fromtimestamp(float(value), tz=timezone.utc).isoformat()
    except (TypeError, ValueError, OSError):
        return str(value or "")


def _format_local_date(value):
    try:
        return datetime.fromtimestamp(float(value)).strftime("%Y-%m-%d %H:%M:%S")
    except (TypeError, ValueError, OSError):
        return str(value or "")


def _format_duration(seconds):
    seconds = int(seconds or 0)
    if seconds <= 0:
        return "0s"
    parts = []
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        if seconds >= size:
            parts.append(f"{seconds // size}{unit}")
            seconds %= size
    return " ".join(parts)


def _get_stats(bw_instances_utils):
    """Merge the stats of all instances : redis data is shared, local data is summed like BunkerWeb metrics"""
    stats = None
    for instance_data in bw_instances_utils.get_data(f"{PLUGIN_ID}/stats"):
        for data in instance_data.values():
            if not isinstance(data, dict) or "source" not in data:
                continue
            alerts = data.get("recent_alerts")
            if not isinstance(alerts, list):
                alerts = []
            if data["source"] == "redis":
                return data | {"recent_alerts": alerts}
            if stats is None:
                stats = data | {"recent_alerts": list(alerts)}
                continue
            stats["unlisted_count"] = stats.get("unlisted_count", 0) + data.get("unlisted_count", 0)
            stats["unlisted_ttl"] = max(stats.get("unlisted_ttl", 0), data.get("unlisted_ttl", 0))
            stats["recent_alerts"].extend(alerts)
    if stats:
        stats["recent_alerts"] = sorted(stats["recent_alerts"], key=lambda alert: alert.get("date", 0), reverse=True)[:RECENT_ALERTS_MAX]
    return stats


def _get_redis_bans():
    """Same logic as the bans page of the web UI"""
    try:
        from app.routes.utils import get_redis_client  # type: ignore

        redis_client = get_redis_client()
    except BaseException:
        return []
    if not redis_client:
        return []

    bans = []
    for pattern, scope in (("bans_ip_*", "global"), ("bans_service_*_ip_*", "service")):
        for key in redis_client.scan_iter(pattern):
            key_str = key.decode("utf-8", "replace")
            if scope == "global":
                service, ip = "_", key_str.replace("bans_ip_", "")
            else:
                service, ip = key_str.replace("bans_service_", "").split("_ip_", 1)
            data = redis_client.get(key)
            if not data:
                continue
            exp = redis_client.ttl(key)
            try:
                ban_data = loads(data.decode("utf-8", "replace"))
            except ValueError:
                ban_data = {"reason": data.decode("utf-8", "replace")}
            ban_data["ban_scope"] = scope
            if scope == "service":
                ban_data["service"] = service
            ban_data["permanent"] = ban_data.get("permanent", False) or exp == 0
            bans.append({"ip": ip, "exp": 0 if ban_data["permanent"] else exp} | ban_data)
    return bans


def _get_bans(bw_instances_utils):
    unique_bans = {}
    for ban in _get_redis_bans() + list(bw_instances_utils.get_bans()):
        scope = ban.get("ban_scope") or ("global" if ban.get("service", "_") == "_" else "service")
        unique_bans.setdefault((ban.get("ip"), scope, ban.get("service", "_")), ban | {"ban_scope": scope})
    return list(unique_bans.values())


def pre_render(**kwargs):
    logger = getLogger("UI")
    ret = {
        "ping_status": {
            "title": f"{SETTING_PREFIX} STATUS",
            "value": "error",
            "col-size": "col-12 col-md-4",
            "card-classes": "h-100",
        },
    }
    try:
        ping_data = kwargs["bw_instances_utils"].get_ping(PLUGIN_ID)
        ret["ping_status"]["value"] = ping_data["status"]
    except BaseException as e:
        logger.debug(format_exc())
        logger.error(f"Failed to get {PLUGIN_ID} ping: {e}")
        ret["error"] = str(e)

    if "error" in ret:
        return ret

    try:
        stats = _get_stats(kwargs["bw_instances_utils"])
        if not stats:
            return ret

        networks = _parse_networks(stats.get("alert_ips"))
        threshold = int(stats.get("threshold") or 0)
        period = int(stats.get("period") or 0)

        if not networks:
            ret["info_ip_filter"] = {
                "title": "IP FILTER",
                "value": "Disabled",
                "description": "Every denied request is notified",
                "col-size": "col-12 col-md-4",
                "card-classes": "h-100",
            }
            return ret

        ret["info_ip_filter"] = {
            "title": "IP FILTER",
            "value": f"{len(networks)} watched IPs/networks",
            "description": (
                f"Unlisted IPs : one summary after {threshold} denied requests within {_format_duration(period)}"
                if threshold > 0
                else "Unlisted IPs : not notified"
            ),
            "col-size": "col-12 col-md-4",
            "card-classes": "h-100",
        }

        if threshold > 0:
            count = int(stats.get("unlisted_count") or 0)
            ttl = int(stats.get("unlisted_ttl") or 0)
            ret["counter_unlisted_denied"] = {
                "title": "UNLISTED DENIED",
                "value": count,
                "subtitle": f"threshold {threshold}" + (f", resets in {_format_duration(ttl)}" if count and ttl else ""),
                "subtitle_color": "danger" if count >= threshold else "muted",
                "svg_color": "danger" if count >= threshold else "primary",
                "col-size": "col-12 col-md-4",
                "card-classes": "h-100",
            }

        banned = sorted(
            (ban for ban in _get_bans(kwargs["bw_instances_utils"]) if _in_networks(ban.get("ip"), networks)),
            key=lambda ban: ban.get("date", 0) or 0,
            reverse=True,
        )
        alerts = stats.get("recent_alerts", [])

        # One row per entry of the watched list with its current ban status and its last notified request
        entries = _parse_entries(stats.get("alert_ips"))
        statuses, last_alerts = [], []
        for _, network in entries:
            entry_bans = sorted({ban.get("ip") for ban in banned if _in_networks(ban.get("ip"), [network])})
            statuses.append(f"Banned ({', '.join(entry_bans)})" if network.num_addresses > 1 and entry_bans else "Banned" if entry_bans else "OK")
            entry_alert = next((alert for alert in alerts if _in_networks(alert.get("ip"), [network])), None)
            last_alerts.append(_format_local_date(entry_alert.get("date")) if entry_alert else "-")
        ret["list_watched_ips"] = {
            "data": {
                "IP/Network": [entry for entry, _ in entries],
                "Status": statuses,
                "Last alert": last_alerts,
            },
            "col-size": "col-12",
        }

        ret["list_banned_watched_ips"] = {
            "data": (
                {
                    "Date": [_format_date(ban.get("date")) for ban in banned],
                    "IP": [str(ban.get("ip", "")) for ban in banned],
                    "Scope": [str(ban.get("ban_scope", "")) for ban in banned],
                    "Service": [str(ban.get("service", "_")) for ban in banned],
                    "Reason": [str(ban.get("reason", "")) for ban in banned],
                    "Expires in": ["permanent" if ban.get("permanent") else _format_duration(ban.get("exp")) for ban in banned],
                }
                if banned
                else {}
            ),
            "col-size": "col-12",
        }

        ret["list_recent_watched_alerts"] = {
            "data": (
                {
                    "Date": [_format_date(alert.get("date")) for alert in alerts],
                    "IP": [str(alert.get("ip", "")) for alert in alerts],
                    "Reason": [str(alert.get("reason", "")) for alert in alerts],
                    "Server name": [str(alert.get("server_name", "")) for alert in alerts],
                }
                if alerts
                else {}
            ),
            "col-size": "col-12",
        }
    except BaseException as e:
        logger.debug(format_exc())
        logger.error(f"Failed to get {PLUGIN_ID} stats: {e}")

    return ret


def slack(**kwargs):
    pass
