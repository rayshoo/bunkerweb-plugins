local cjson = require("cjson")
local class = require("middleclass")
local http = require("resty.http")
local ipmatcher = require("resty.ipmatcher")
local clusterstore = require("bunkerweb.clusterstore")
local plugin = require("bunkerweb.plugin")
local utils = require("bunkerweb.utils")

local webhook = class("webhook", plugin)

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

local UNLISTED_COUNTER_PREFIX = "plugin_webhook_unlisted_count_"
local WATCHED_ALERTS_KEY = "plugin_webhook_watched_alerts"
local UNLISTED_ALERTS_KEY = "plugin_webhook_unlisted_alerts"
local BAN_ALERTS_KEY = "plugin_webhook_ban_alerts"
local BAN_ALERTED_PREFIX = "plugin_webhook_ban_alerted_"
-- Keep the message bounded so the remote endpoint never splits it (which breaks the code block)
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
local ALERTS_MAX = 20

-- Per-worker cache of the ipmatcher built from WEBHOOK_ALERT_IPS
local alert_ips_cache = { raw = nil, matcher = nil }

function webhook:initialize(ctx)
	-- Call parent initialize
	plugin.initialize(self, "webhook", ctx)
end

-- Returns the ipmatcher for WEBHOOK_ALERT_IPS or nil if the list is empty
function webhook:get_alert_ips_matcher()
	local raw = self.variables["WEBHOOK_ALERT_IPS"] or ""
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
			self.logger:log(ERR, "can't parse WEBHOOK_ALERT_IPS, notifying all denied requests : " .. err)
		end
	end
	alert_ips_cache.raw = raw
	alert_ips_cache.matcher = matcher
	return matcher
end

-- Increments the per-IP counter of denied requests from an unlisted IP (shared through redis if enabled)
-- The counter expires period seconds after the first denied request from that IP,
-- so at most one notification is sent per IP per period
function webhook:incr_unlisted(ip, period)
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
function webhook:push_alert(list_key, alert)
	local value = encode(alert)
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
function webhook:mark_ban_alerted(ip, ttl)
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
function webhook:read_alerts(cs, list_key)
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
function webhook:get_stats()
	local stats = {
		source = "local",
		alert_ips = self.variables["WEBHOOK_ALERT_IPS"] or "",
		threshold = tonumber(self.variables["WEBHOOK_UNLISTED_THRESHOLD"]) or 0,
		period = tonumber(self.variables["WEBHOOK_UNLISTED_PERIOD"]) or 600,
		watched_alerts = {},
		unlisted_alerts = {},
		ban_alerts = {},
	}
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect(true)
		if ok then
			stats.source = "redis"
			stats.watched_alerts = self:read_alerts(cs, WATCHED_ALERTS_KEY)
			stats.unlisted_alerts = self:read_alerts(cs, UNLISTED_ALERTS_KEY)
			stats.ban_alerts = self:read_alerts(cs, BAN_ALERTS_KEY)
			cs:close()
			return stats
		end
		self.logger:log(ERR, "can't get stats from redis, falling back to local : " .. tostring(err))
	end
	stats.watched_alerts = self:read_alerts(nil, WATCHED_ALERTS_KEY)
	stats.unlisted_alerts = self:read_alerts(nil, UNLISTED_ALERTS_KEY)
	stats.ban_alerts = self:read_alerts(nil, BAN_ALERTS_KEY)
	return stats
end
function webhook:log(bypass_use_webhook)
	-- Check if webhook is enabled
	if not bypass_use_webhook then
		if self.variables["USE_WEBHOOK"] ~= "yes" then
			return self:ret(true, "webhook plugin not enabled")
		end
	end
	-- Check if request is denied
	local reason, reason_data = get_reason(self.ctx)
	if reason == nil then
		return self:ret(true, "request not denied")
	end
	-- Filter by WEBHOOK_ALERT_IPS (empty list means every denied request is notified)
	local prefix = ""
	local watched = false
	local matcher = self:get_alert_ips_matcher()
	if matcher then
		local match, err = matcher:match(self.ctx.bw.remote_addr)
		if err then
			self.logger:log(ERR, "can't match IP " .. self.ctx.bw.remote_addr .. " : " .. err)
		end
		if not match then
			if (tonumber(self.variables["WEBHOOK_UNLISTED_THRESHOLD"]) or 0) <= 0 then
				return self:ret(true, "IP not in WEBHOOK_ALERT_IPS")
			end
			-- Counting is done in a timer because redis can't be used in the log phase
			local hdr
			hdr, err = ngx_timer.at(0, self.unlisted, self, self.ctx.bw.remote_addr, reason)
			if not hdr then
				return self:ret(true, "can't create unlisted timer : " .. err)
			end
			return self:ret(true, "scheduled timer for unlisted IP")
		end
		watched = true
		prefix = "🚨 Denied request from a watched IP (WEBHOOK_ALERT_IPS)\n"
	end
	-- Compute data
	-- Body kept inside a single code block, bounded so the remote endpoint never splits it
	local body = "Denied request for IP "
		.. self.ctx.bw.remote_addr
		.. " (reason = "
		.. reason
		.. " / reason data = "
		.. truncate(encode(reason_data or {}), REASON_DATA_MAX)
		.. ").\n\nRequest data :\n\n"
		.. (ngx.var.request or "")
		.. "\n"
	local headers, err = ngx_req.get_headers()
	if not headers then
		body = body .. "error while getting headers : " .. err
	else
		for header, value in pairs(headers) do
			body = body .. header .. ": " .. value .. "\n"
		end
	end
	local data = {}
	data.content = prefix .. "```" .. truncate(body, MESSAGE_MAX) .. "```"
	-- Send request
	local hdr
	if watched then
		local alert = {
			date = ngx_now(),
			ip = self.ctx.bw.remote_addr,
			reason = reason,
			server_name = self.ctx.bw.server_name,
		}
		hdr, err = ngx_timer.at(0, self.watched, self, data, alert)
	else
		hdr, err = ngx_timer.at(0, self.send, self, data)
	end
	if not hdr then
		return self:ret(true, "can't create report timer : " .. err)
	end
	return self:ret(true, "scheduled timer")
end

-- luacheck: ignore 212
function webhook.watched(premature, self, data, alert)
	-- A watched IP that is actually banned is a critical event : notify once per ban (with an
	-- optional mention) and suppress the per-request block alerts while the ban lasts
	if self.variables["WEBHOOK_BAN_ALERT"] == "yes" then
		local banned, _, ttl = is_banned(alert.ip, alert.server_name)
		if banned then
			if self:mark_ban_alerted(alert.ip, ttl) then
				local duration = (ttl == nil or ttl == 0) and "permanent" or (tostring(ttl) .. "s")
				self:push_alert(BAN_ALERTS_KEY, {
					date = ngx_now(),
					ip = alert.ip,
					reason = alert.reason,
					server_name = alert.server_name,
					ttl = ttl or 0,
				})
				local mention = self.variables["WEBHOOK_BAN_MENTION"] or ""
				webhook.send(premature, self, {
					content = (mention ~= "" and (mention .. "\n") or "")
						.. "🚫 A watched IP is BANNED (WEBHOOK_ALERT_IPS)\n```IP "
						.. alert.ip
						.. " is banned ("
						.. duration
						.. ") on "
						.. tostring(alert.server_name)
						.. " (reason = "
						.. alert.reason
						.. "). This is one of your own servers.```",
				})
			end
			-- Banned : do not send the normal block alert (avoids flooding while banned)
			return
		end
	end
	self:push_alert(WATCHED_ALERTS_KEY, alert)
	webhook.send(premature, self, data)
end

function webhook.unlisted(premature, self, ip, reason)
	local threshold = tonumber(self.variables["WEBHOOK_UNLISTED_THRESHOLD"]) or 0
	local period = tonumber(self.variables["WEBHOOK_UNLISTED_PERIOD"]) or 600
	local count = self:incr_unlisted(ip, period)
	-- Only notify once per IP, when its own count reaches the threshold
	if count ~= threshold then
		return
	end
	self:push_alert(UNLISTED_ALERTS_KEY, {
		date = ngx_now(),
		ip = ip,
		reason = reason,
		count = count,
		period = period,
	})
	webhook.send(premature, self, {
		content = "```IP "
			.. ip
			.. " (not in WEBHOOK_ALERT_IPS) has been denied "
			.. tostring(count)
			.. " times within "
			.. tostring(period)
			.. "s (reason = "
			.. reason
			.. "). No more notification about this IP until the period ends.```",
	})
end

function webhook.send(premature, self, data)
	local httpc, err = http_new()
	if not httpc then
		self.logger:log(ERR, "can't instantiate http object : " .. err)
	end
	local res, err_http = httpc:request_uri(self.variables["WEBHOOK_URL"], {
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
	if self.variables["WEBHOOK_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
		self.logger:log(WARN, "HTTP endpoint is rate-limiting us, retrying in " .. res.headers["Retry-After"] .. "s")
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
		return
	end
	self.logger:log(INFO, "request sent to webhook")
end

function webhook:log_default()
	-- Check if webhook is activated
	local check, err = has_variable("USE_WEBHOOK", "yes")
	if check == nil then
		return self:ret(false, "error while checking variable USE_WEBHOOK (" .. err .. ")")
	end
	if not check then
		return self:ret(true, "webhook plugin not enabled")
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

function webhook:api()
	if self.ctx.bw.uri == "/webhook/stats" and self.ctx.bw.request_method == "GET" then
		return self:ret(true, self:get_stats(), HTTP_OK)
	end
	if self.ctx.bw.uri == "/webhook/ping" and self.ctx.bw.request_method == "POST" then
		-- Check webhook connection
		local check, err = has_variable("USE_WEBHOOK", "yes")
		if check == nil then
			return self:ret(true, "error while checking variable USE_WEBHOOK (" .. err .. ")")
		end
		if not check then
			return self:ret(true, "Webhook plugin not enabled")
		end

		-- Send test data to webhook webhook
		local data = {
			content = "```Test message from bunkerweb```",
		}
		-- Send request
		local httpc
		httpc, err = http_new()
		if not httpc then
			self.logger:log(ERR, "can't instantiate http object : " .. err)
		end
		local res, err_http = httpc:request_uri(self.variables["WEBHOOK_URL"], {
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
		if self.variables["WEBHOOK_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
			return self:ret(
				true,
				"webhook API is rate-limiting us, retry in " .. res.headers["Retry-After"] .. "s",
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

return webhook
