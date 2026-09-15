local cjson = require("cjson")
local class = require("middleclass")
local http = require("resty.http")
local ipmatcher = require("resty.ipmatcher")
local clusterstore = require("bunkerweb.clusterstore")
local plugin = require("bunkerweb.plugin")
local utils = require("bunkerweb.utils")

local slack = class("slack", plugin)

local ngx = ngx
local ngx_req = ngx.req
local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO
local ngx_timer = ngx.timer
local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_TOO_MANY_REQUESTS = ngx.HTTP_TOO_MANY_REQUESTS
local HTTP_OK = ngx.HTTP_OK
local http_new = http.new
local has_variable = utils.has_variable
local get_variable = utils.get_variable
local get_reason = utils.get_reason
local is_banned = utils.is_banned
local tostring = tostring
local tonumber = tonumber
local encode = cjson.encode
local decode = cjson.decode
local ngx_now = ngx.now
local table_insert = table.insert
local table_sort = table.sort
local ipmatcher_new = ipmatcher.new
local shared_datastore = ngx.shared.datastore or ngx.shared.datastore_stream

local UNLISTED_COUNTER_PREFIX = "plugin_slack_unlisted_count_"
local WATCHED_ALERTS_KEY = "plugin_slack_watched_alerts"
local UNLISTED_ALERTS_KEY = "plugin_slack_unlisted_alerts"
local BAN_ALERTS_KEY = "plugin_slack_ban_alerts"
local BAN_ALERTED_PREFIX = "plugin_slack_ban_alerted_"
local DELIVERIES_KEY = "plugin_slack_deliveries"
local RESPONSE_MAX = 500
-- Slack silently splits or drops oversized messages, which breaks the code block ; keep it bounded
local MESSAGE_MAX = 3000
local REASON_DATA_MAX = 800

-- Truncates a string to at most max characters, adding a marker when cut
local function truncate(str, max)
	str = tostring(str or "")
	if #str > max then
		return str:sub(1, max) .. "…(truncated)"
	end
	return str
end

-- JSON-escapes a value so it can be injected inside a quoted string of a JSON template
local function json_escape(value)
	local quoted = encode(tostring(value or ""))
	return quoted:sub(2, -2)
end

-- Renders a template : resolves {{#if var}}...{{/if}} sections then substitutes {{ var }}
-- with JSON-escaped values (nesting is not supported ; the result is validated as JSON by the caller)
local function render_template(tmpl, vars)
	local out = tmpl
	local changed = true
	while changed do
		changed = false
		out = out:gsub("{{#if%s+([%w_]+)%s*}}(.-){{/if}}", function(name, inner)
			changed = true
			local v = vars[name]
			if v ~= nil and v ~= "" and v ~= "0" and v ~= false then
				return inner
			end
			return ""
		end)
	end
	out = out:gsub("{{%s*([%w_]+)%s*}}", function(name)
		local v = vars[name]
		if v == nil then
			return ""
		end
		return json_escape(v)
	end)
	return out
end

local ALERTS_MAX = 20

-- Per-worker cache of the ipmatcher built from SLACK_ALERT_IPS
local alert_ips_cache = { raw = nil, matcher = nil }

function slack:initialize(ctx)
	-- Call parent initialize
	plugin.initialize(self, "slack", ctx)
end

-- Returns the ipmatcher for SLACK_ALERT_IPS or nil if the list is empty
function slack:get_alert_ips_matcher()
	local raw = self.variables["SLACK_ALERT_IPS"] or ""
	if alert_ips_cache.raw == raw then
		return alert_ips_cache.matcher
	end
	local ips = {}
	for ip in raw:gmatch("%S+") do
		ips[#ips + 1] = ip
	end
	local matcher, err
	if #ips > 0 then
		matcher, err = ipmatcher_new(ips)
		if not matcher then
			-- Fallback to notifying every denied request (matcher stays nil)
			self.logger:log(ERR, "can't parse SLACK_ALERT_IPS, notifying all denied requests : " .. err)
		end
	end
	alert_ips_cache.raw = raw
	alert_ips_cache.matcher = matcher
	return matcher
end

-- Increments the per-IP counter of denied requests from an unlisted IP (shared through redis if enabled)
-- The counter expires period seconds after the first denied request from that IP,
-- so at most one notification is sent per IP per period
function slack:incr_unlisted(ip, period)
	local key = UNLISTED_COUNTER_PREFIX .. ip
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect()
		if ok then
			local ret
			ret, err = cs:call(
				"eval",
				[[
				local count = redis.call("INCR", KEYS[1])
				if count == 1 then
					redis.call("EXPIRE", KEYS[1], ARGV[1])
				end
				return count
			]],
				1,
				key,
				period
			)
			cs:close()
			if ret then
				return tonumber(ret)
			end
		end
		self.logger:log(ERR, "can't increment unlisted counter on redis, falling back to local : " .. tostring(err))
	end
	if not shared_datastore then
		self.logger:log(ERR, "shared dict datastore not found, can't count unlisted IPs")
		return nil
	end
	local count, err = shared_datastore:incr(key, 1, 0, period)
	if not count then
		self.logger:log(ERR, "can't increment unlisted counter : " .. err)
		return nil
	end
	return count
end

-- Stores a notification in a capped list (shared through redis if enabled)
function slack:push_alert(list_key, alert)
	local encoded, value = pcall(encode, alert)
	if not encoded then
		self.logger:log(ERR, "can't encode alert : " .. tostring(value))
		return
	end
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect()
		if ok then
			local ret
			ret, err = cs:call(
				"eval",
				[[
				redis.call("LPUSH", KEYS[1], ARGV[1])
				redis.call("LTRIM", KEYS[1], 0, tonumber(ARGV[2]) - 1)
				return 1
			]],
				1,
				list_key,
				value,
				ALERTS_MAX
			)
			cs:close()
			if ret then
				return
			end
		end
		self.logger:log(ERR, "can't store alert on redis, falling back to local : " .. tostring(err))
	end
	if not shared_datastore then
		return
	end
	-- Local ring buffer of ALERTS_MAX entries
	local idx, err = shared_datastore:incr(list_key .. "_idx", 1, 0)
	if not idx then
		self.logger:log(ERR, "can't store alert : " .. err)
		return
	end
	shared_datastore:set(list_key .. "_" .. tostring(idx % ALERTS_MAX), value)
end

-- Marks that a ban alert was already sent for this IP, returns true only the first time (per ban)
-- The mark expires with the ban so a later re-ban notifies again
function slack:mark_ban_alerted(ip, ttl)
	local key = BAN_ALERTED_PREFIX .. ip
	local expire = (ttl and ttl > 0) and ttl or 86400
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect()
		if ok then
			local ret
			ret, err = cs:call("set", key, "1", "NX", "EX", expire)
			cs:close()
			if ret ~= nil then
				return ret ~= ngx.null -- "OK" when set, ngx.null when it already existed
			end
		end
		self.logger:log(ERR, "can't mark ban alert on redis, falling back to local : " .. tostring(err))
	end
	if not shared_datastore then
		return true
	end
	local ok = shared_datastore:add(key, "1", expire) -- add sets only if the key is absent
	return ok == true
end

-- Reads a capped list of notifications, newest first
function slack:read_alerts(cs, list_key)
	local alerts = {}
	if cs then
		local values = cs:call("lrange", list_key, 0, -1)
		if type(values) == "table" then
			for _, value in ipairs(values) do
				local decoded, alert = pcall(decode, value)
				if decoded then
					table_insert(alerts, alert)
				end
			end
		end
		return alerts
	end
	if not shared_datastore then
		return alerts
	end
	for i = 0, ALERTS_MAX - 1 do
		local value = shared_datastore:get(list_key .. "_" .. tostring(i))
		if value then
			local decoded, alert = pcall(decode, value)
			if decoded then
				table_insert(alerts, alert)
			end
		end
	end
	table_sort(alerts, function(a, b)
		return (a.date or 0) > (b.date or 0)
	end)
	return alerts
end

-- Returns the data displayed on the plugin page of the web UI
function slack:get_stats()
	local stats = {
		source = "local",
		alert_ips = self.variables["SLACK_ALERT_IPS"] or "",
		format = self.variables["SLACK_FORMAT"] or "default",
		threshold = tonumber(self.variables["SLACK_UNLISTED_THRESHOLD"]) or 0,
		period = tonumber(self.variables["SLACK_UNLISTED_PERIOD"]) or 600,
		watched_alerts = {},
		unlisted_alerts = {},
		ban_alerts = {},
		deliveries = {},
	}
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect(true)
		if ok then
			stats.source = "redis"
			stats.watched_alerts = self:read_alerts(cs, WATCHED_ALERTS_KEY)
			stats.unlisted_alerts = self:read_alerts(cs, UNLISTED_ALERTS_KEY)
			stats.ban_alerts = self:read_alerts(cs, BAN_ALERTS_KEY)
			stats.deliveries = self:read_alerts(cs, DELIVERIES_KEY)
			cs:close()
			return stats
		end
		self.logger:log(ERR, "can't get stats from redis, falling back to local : " .. tostring(err))
	end
	stats.watched_alerts = self:read_alerts(nil, WATCHED_ALERTS_KEY)
	stats.unlisted_alerts = self:read_alerts(nil, UNLISTED_ALERTS_KEY)
	stats.ban_alerts = self:read_alerts(nil, BAN_ALERTS_KEY)
	stats.deliveries = self:read_alerts(nil, DELIVERIES_KEY)
	return stats
end

-- Builds the normalized variables exposed to templates (all defined, empty when not applicable)
function slack:build_vars(event, info)
	local rd = info.reason_data or {}
	local function join(t)
		if type(t) == "table" then
			return table.concat(t, ", ")
		end
		return tostring(t or "")
	end
	return {
		event = event,
		is_block = event == "block" and "1" or "",
		is_ban = event == "ban" and "1" or "",
		is_unlisted = event == "unlisted" and "1" or "",
		watched = info.watched and "1" or "",
		ip = info.ip or "",
		reason = info.reason or "",
		reason_data = truncate(encode(rd), REASON_DATA_MAX),
		server_name = info.server_name or "",
		method = info.method or "",
		uri = info.uri or "",
		status = tostring(info.status or ""),
		user_agent = info.user_agent or "",
		request = truncate(info.request or "", MESSAGE_MAX),
		request_id = info.request_id or "",
		date = info.date or "",
		headers = truncate(info.headers or "", MESSAGE_MAX),
		rule_ids = join(rd.ids),
		rule_msgs = join(rd.msgs),
		ban_duration = info.ban_duration or "",
		count = info.count and tostring(info.count) or "",
		period = info.period and tostring(info.period) or "",
		-- The configured ban mention is always available ; the user decides where to use it
		mention = self.variables["SLACK_BAN_MENTION"] or "",
	}
end

-- Our polished built-in message (no template knowledge required)
function slack:default_message(event, info)
	if event == "ban" then
		local mention = self.variables["SLACK_BAN_MENTION"] or ""
		return {
			text = (mention ~= "" and (mention .. "\n") or "")
				.. ":no_entry: *A watched IP is BANNED* (SLACK_ALERT_IPS)\n```IP "
				.. info.ip
				.. " is banned ("
				.. (info.ban_duration or "")
				.. ") on "
				.. tostring(info.server_name)
				.. " (reason = "
				.. info.reason
				.. "). This is one of your own servers.```",
		}
	elseif event == "unlisted" then
		return {
			text = "```IP "
				.. info.ip
				.. " (not in SLACK_ALERT_IPS) has been denied "
				.. tostring(info.count)
				.. " times within "
				.. tostring(info.period)
				.. "s (reason = "
				.. info.reason
				.. "). No more notification about this IP until the period ends.```",
		}
	end
	local prefix = info.watched and ":rotating_light: *Denied request from a watched IP (SLACK_ALERT_IPS)*\n" or ""
	local body = "Denied request for IP "
		.. info.ip
		.. " (reason = "
		.. info.reason
		.. " / reason data = "
		.. truncate(encode(info.reason_data or {}), REASON_DATA_MAX)
		.. ").\n\nRequest data :\n\n"
		.. (info.request or "")
		.. "\n"
		.. (info.headers or "")
	return { text = prefix .. "```" .. truncate(body, MESSAGE_MAX) .. "```" }
end

-- Returns the payload for an event : a raw JSON string when a valid custom template is set,
-- otherwise the built-in table (default / blockkit). Invalid templates fall back and are recorded.
function slack:format_message(event, info)
	local format = self.variables["SLACK_FORMAT"] or "default"
	if format == "template" then
		local tmpl = self.variables["SLACK_TEMPLATE"] or ""
		if tmpl ~= "" then
			local rendered = render_template(tmpl, self:build_vars(event, info))
			if pcall(decode, rendered) then
				return rendered
			end
			self.logger:log(ERR, "SLACK_TEMPLATE produced invalid JSON, falling back to the default format")
			self:record_delivery(false, nil, "invalid SLACK_TEMPLATE JSON (fell back to default)", truncate(rendered, RESPONSE_MAX))
		end
	end
	-- "blockkit" is added in a later step ; until then it uses the default layout
	return self:default_message(event, info)
end

function slack:log(bypass_use_slack)
	-- Check if slack is enabled
	if not bypass_use_slack then
		if self.variables["USE_SLACK"] ~= "yes" then
			return self:ret(true, "slack plugin not enabled")
		end
	end
	-- Check if request is denied
	local reason, reason_data = get_reason(self.ctx)
	if reason == nil then
		return self:ret(true, "request not denied")
	end
	-- Collect the request headers once, as a formatted string
	local headers_str = ""
	local headers, herr = ngx_req.get_headers()
	if not headers then
		headers_str = "error while getting headers : " .. tostring(herr)
	else
		for header, value in pairs(headers) do
			headers_str = headers_str .. header .. ": " .. value .. "\n"
		end
	end
	-- Normalized context passed to the notification timers
	local info = {
		ip = self.ctx.bw.remote_addr,
		reason = reason,
		reason_data = reason_data,
		server_name = self.ctx.bw.server_name,
		request = ngx.var.request or "",
		method = self.ctx.bw.request_method,
		uri = self.ctx.bw.request_uri,
		status = ngx.status,
		user_agent = self.ctx.bw.http_user_agent,
		request_id = self.ctx.bw.request_id,
		date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		headers = headers_str,
		watched = false,
	}
	-- Filter by SLACK_ALERT_IPS (empty list means every denied request is notified)
	local matcher = self:get_alert_ips_matcher()
	if matcher then
		local match, err = matcher:match(info.ip)
		if err then
			self.logger:log(ERR, "can't match IP " .. info.ip .. " : " .. err)
		end
		if not match then
			if (tonumber(self.variables["SLACK_UNLISTED_THRESHOLD"]) or 0) <= 0 then
				return self:ret(true, "IP not in SLACK_ALERT_IPS")
			end
			-- Counting is done in a timer because redis can't be used in the log phase
			local hdr
			hdr, err = ngx_timer.at(0, self.unlisted, self, info)
			if not hdr then
				return self:ret(true, "can't create unlisted timer : " .. err)
			end
			return self:ret(true, "scheduled timer for unlisted IP")
		end
		info.watched = true
	end
	local hdr, err = ngx_timer.at(0, self.notify, self, info)
	if not hdr then
		return self:ret(true, "can't create report timer : " .. err)
	end
	return self:ret(true, "scheduled timer")
end

-- luacheck: ignore 212
function slack.notify(premature, self, info)
	-- A watched IP that is actually banned is a critical event : notify once per ban and
	-- suppress the per-request block alerts while the ban lasts
	if info.watched and self.variables["SLACK_BAN_ALERT"] == "yes" then
		local banned, _, ttl = is_banned(info.ip, info.server_name)
		if banned then
			if self:mark_ban_alerted(info.ip, ttl) then
				info.ban_duration = (ttl == nil or ttl == 0) and "permanent" or (tostring(ttl) .. "s")
				self:push_alert(BAN_ALERTS_KEY, {
					date = ngx_now(),
					ip = info.ip,
					reason = info.reason,
					server_name = info.server_name,
					ttl = ttl or 0,
				})
				slack.send(premature, self, self:format_message("ban", info))
			end
			return
		end
	end
	if info.watched then
		self:push_alert(WATCHED_ALERTS_KEY, {
			date = ngx_now(),
			ip = info.ip,
			reason = info.reason,
			server_name = info.server_name,
		})
	end
	slack.send(premature, self, self:format_message("block", info))
end

function slack.unlisted(premature, self, info)
	local threshold = tonumber(self.variables["SLACK_UNLISTED_THRESHOLD"]) or 0
	local period = tonumber(self.variables["SLACK_UNLISTED_PERIOD"]) or 600
	local count = self:incr_unlisted(info.ip, period)
	-- Only notify once per IP, when its own count reaches the threshold
	if count ~= threshold then
		return
	end
	info.count = count
	info.period = period
	self:push_alert(UNLISTED_ALERTS_KEY, {
		date = ngx_now(),
		ip = info.ip,
		reason = info.reason,
		count = count,
		period = period,
	})
	slack.send(premature, self, self:format_message("unlisted", info))
end

-- Records the outcome of a webhook delivery so it can be shown in the web UI
function slack:record_delivery(ok, status, err, body)
	self:push_alert(DELIVERIES_KEY, {
		date = ngx_now(),
		ok = ok and true or false,
		status = status or 0,
		error = err and truncate(err, RESPONSE_MAX) or "",
		response = body and truncate(body, RESPONSE_MAX) or "",
	})
end

function slack.send(premature, self, data)
	local httpc, err = http_new()
	if not httpc then
		self.logger:log(ERR, "can't instantiate http object : " .. err)
		self:record_delivery(false, nil, "can't instantiate http object : " .. tostring(err), nil)
		return
	end
	local res, err_http = httpc:request_uri(self.variables["SLACK_WEBHOOK_URL"], {
		method = "POST",
		headers = {
			["Content-Type"] = "application/json",
		},
		-- data is a raw JSON string when rendered from a custom template, a table otherwise
		body = (type(data) == "string") and data or encode(data),
	})
	httpc:close()
	if not res then
		self.logger:log(ERR, "error while sending request : " .. tostring(err_http))
		self:record_delivery(false, nil, tostring(err_http), nil)
		return
	end
	if self.variables["SLACK_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
		self.logger:log(WARN, "slack API is rate-limiting us, retrying in " .. res.headers["Retry-After"] .. "s")
		self:record_delivery(false, res.status, "rate-limited, retrying in " .. res.headers["Retry-After"] .. "s", res.body)
		local hdr
		hdr, err = ngx_timer.at(res.headers["Retry-After"], self.send, self, data)
		if not hdr then
			self.logger:log(ERR, "can't create report timer : " .. err)
			return
		end
		return
	end
	if res.status < 200 or res.status > 299 then
		self.logger:log(ERR, "request returned status " .. tostring(res.status))
		self:record_delivery(false, res.status, nil, res.body)
		return
	end
	self.logger:log(INFO, "request sent to webhook")
	self:record_delivery(true, res.status, nil, res.body)
end

function slack:log_default()
	-- Check if slack is activated
	local check, err = has_variable("USE_SLACK", "yes")
	if check == nil then
		return self:ret(false, "error while checking variable USE_slack (" .. err .. ")")
	end
	if not check then
		return self:ret(true, "slack plugin not enabled")
	end
	-- Check if default server is disabled
	check, err = get_variable("DISABLE_DEFAULT_SERVER", false)
	if check == nil then
		return self:ret(false, "error while getting variable DISABLE_DEFAULT_SERVER (" .. err .. ")")
	end
	if check ~= "yes" then
		return self:ret(true, "default server not disabled")
	end
	-- Call log method
	return self:log(true)
end

function slack:api()
	if self.ctx.bw.uri == "/slack/stats" and self.ctx.bw.request_method == "GET" then
		return self:ret(true, self:get_stats(), HTTP_OK)
	end
	if self.ctx.bw.uri == "/slack/ping" and self.ctx.bw.request_method == "POST" then
		-- Check slack connection
		local check, err = has_variable("USE_SLACK", "yes")
		if check == nil then
			return self:ret(true, "error while checking variable USE_SLACK (" .. err .. ")")
		end
		if not check then
			return self:ret(true, "Slack plugin not enabled")
		end

		-- Send test data to slack webhook
		local data = {
			text = "```Test message from bunkerweb```",
		}
		-- Send request
		local httpc
		httpc, err = http_new()
		if not httpc then
			self.logger:log(ERR, "can't instantiate http object : " .. err)
		end
		local res, err_http = httpc:request_uri(self.variables["SLACK_WEBHOOK_URL"], {
			method = "POST",
			headers = {
				["Content-Type"] = "application/json",
			},
			body = encode(data),
		})
		httpc:close()
		if not res then
			self.logger:log(ERR, "error while sending request : " .. err_http)
		end
		if self.variables["SLACK_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
			return self:ret(
				true,
				"slack API is rate-limiting us, retry in " .. res.headers["Retry-After"] .. "s",
				HTTP_TOO_MANY_REQUESTS
			)
		end
		if res.status < 200 or res.status > 299 then
			return self:ret(true, "request returned status " .. tostring(res.status), HTTP_INTERNAL_SERVER_ERROR)
		end
		return self:ret(true, "request sent to webhook", HTTP_OK)
	end
	return self:ret(false, "success")
end

return slack
