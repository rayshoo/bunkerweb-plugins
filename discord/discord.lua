local cjson = require("cjson")
local class = require("middleclass")
local http = require("resty.http")
local ipmatcher = require("resty.ipmatcher")
local clusterstore = require("bunkerweb.clusterstore")
local plugin = require("bunkerweb.plugin")
local utils = require("bunkerweb.utils")

local discord = class("discord", plugin)

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
local tostring = tostring
local tonumber = tonumber
local len = string.len
local sub = string.sub
local format = string.format
local encode = cjson.encode
local floor = math.floor
local date = os.date
local decode = cjson.decode
local ngx_now = ngx.now
local table_insert = table.insert
local table_sort = table.sort
local ipmatcher_new = ipmatcher.new
local shared_datastore = ngx.shared.datastore or ngx.shared.datastore_stream

local UNLISTED_COUNTER_PREFIX = "plugin_discord_unlisted_count_"
local WATCHED_ALERTS_KEY = "plugin_discord_watched_alerts"
local UNLISTED_ALERTS_KEY = "plugin_discord_unlisted_alerts"
local ALERTS_MAX = 20

-- Per-worker cache of the ipmatcher built from DISCORD_ALERT_IPS
local alert_ips_cache = { raw = nil, matcher = nil }

function discord:initialize(ctx)
	-- Call parent initialize
	plugin.initialize(self, "discord", ctx)
end

-- Returns the ipmatcher for DISCORD_ALERT_IPS or nil if the list is empty
function discord:get_alert_ips_matcher()
	local raw = self.variables["DISCORD_ALERT_IPS"] or ""
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
			self.logger:log(ERR, "can't parse DISCORD_ALERT_IPS, notifying all denied requests : " .. err)
		end
	end
	alert_ips_cache.raw = raw
	alert_ips_cache.matcher = matcher
	return matcher
end

-- Increments the per-IP counter of denied requests from an unlisted IP (shared through redis if enabled)
-- The counter expires period seconds after the first denied request from that IP,
-- so at most one notification is sent per IP per period
function discord:incr_unlisted(ip, period)
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
function discord:push_alert(list_key, alert)
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

-- Reads a capped list of notifications, newest first
function discord:read_alerts(cs, list_key)
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
function discord:get_stats()
	local stats = {
		source = "local",
		alert_ips = self.variables["DISCORD_ALERT_IPS"] or "",
		threshold = tonumber(self.variables["DISCORD_UNLISTED_THRESHOLD"]) or 0,
		period = tonumber(self.variables["DISCORD_UNLISTED_PERIOD"]) or 600,
		watched_alerts = {},
		unlisted_alerts = {},
	}
	if self.use_redis then
		local cs = clusterstore:new()
		local ok, err = cs:connect(true)
		if ok then
			stats.source = "redis"
			stats.watched_alerts = self:read_alerts(cs, WATCHED_ALERTS_KEY)
			stats.unlisted_alerts = self:read_alerts(cs, UNLISTED_ALERTS_KEY)
			cs:close()
			return stats
		end
		self.logger:log(ERR, "can't get stats from redis, falling back to local : " .. tostring(err))
	end
	stats.watched_alerts = self:read_alerts(nil, WATCHED_ALERTS_KEY)
	stats.unlisted_alerts = self:read_alerts(nil, UNLISTED_ALERTS_KEY)
	return stats
end
function discord:log(bypass_use_discord)
	-- Check if discord is enabled
	if not bypass_use_discord then
		if self.variables["USE_DISCORD"] ~= "yes" then
			return self:ret(true, "discord plugin not enabled")
		end
	end
	-- Check if request is denied
	local reason, reason_data = get_reason(self.ctx)
	if reason == nil then
		return self:ret(true, "request not denied")
	end
	-- Compute data
	local timestamp = ngx_req.start_time()
	local formattedTimestamp = date("!%Y-%m-%dT%H:%M:%S", timestamp)
	local milliseconds = floor((timestamp - floor(timestamp)) * 1000)
	local formatField = function(inputString)
		if len(inputString) <= 1021 then
			return inputString
		else
			return sub(inputString, 1, 1021) .. "..."
		end
	end
	local embedTimestamp = formattedTimestamp .. "." .. format("%03d", milliseconds) .. "Z"

	-- Filter by DISCORD_ALERT_IPS (empty list means every denied request is notified)
	local title = "Denied request for IP " .. self.ctx.bw.remote_addr
	local color = 0x125678
	local watched = false
	local matcher = self:get_alert_ips_matcher()
	if matcher then
		local match, err = matcher:match(self.ctx.bw.remote_addr)
		if err then
			self.logger:log(ERR, "can't match IP " .. self.ctx.bw.remote_addr .. " : " .. err)
		end
		if not match then
			if (tonumber(self.variables["DISCORD_UNLISTED_THRESHOLD"]) or 0) <= 0 then
				return self:ret(true, "IP not in DISCORD_ALERT_IPS")
			end
			-- Counting is done in a timer because redis can't be used in the log phase
			local hdr
			hdr, err = ngx_timer.at(0, self.unlisted, self, self.ctx.bw.remote_addr, reason, embedTimestamp)
			if not hdr then
				return self:ret(true, "can't create unlisted timer : " .. err)
			end
			return self:ret(true, "scheduled timer for unlisted IP")
		end
		watched = true
		title = "🚨 Denied request from watched IP " .. self.ctx.bw.remote_addr
		color = 0xE74C3C
	end

	local data = {
		username = "BunkerWeb",
		embeds = {
			{
				title = title,
				timestamp = embedTimestamp,
				color = color,
				provider = {
					name = "BunkerWeb",
					url = "https://github.com/bunkerity/bunkerweb",
				},
				author = {
					name = "BunkerWeb's Discord plugin",
					url = "https://github.com/bunkerity/bunkerweb",
					icon_url = "https://raw.githubusercontent.com/bunkerity/bunkerweb-plugins/main/logo.png",
				},
				fields = {
					{
						name = "Request data",
						value = formatField(ngx.var.request),
						inline = false,
					},
					{
						name = "Reason",
						value = formatField(reason),
						inline = false,
					},
					{
						name = "Reason data",
						value = formatField(encode(reason_data or {})),
						inline = false,
					},
				},
			},
		},
	}
	local headers, err = ngx_req.get_headers()
	if not headers then
		data.embeds[1].description = "**error while getting headers : " .. err .. "**"
	else
		local count = 0
		for _ in pairs(headers) do
			count = count + 1
		end
		if count > 23 then
			data.embeds[1].description = "Headers :\n```"
			for header, value in pairs(headers) do
				data.embeds[1].description = data.embeds[1].description .. header .. ": " .. value .. "\n"
			end
			data.embeds[1].description = data.embeds[1].description .. "```"
		else
			for header, value in pairs(headers) do
				table.insert(data.embeds[1].fields, {
					name = header,
					value = formatField(value),
					inline = true,
				})
			end
		end
	end
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
function discord.watched(premature, self, data, alert)
	self:push_alert(WATCHED_ALERTS_KEY, alert)
	discord.send(premature, self, data)
end

function discord.unlisted(premature, self, ip, reason, embedTimestamp)
	local threshold = tonumber(self.variables["DISCORD_UNLISTED_THRESHOLD"]) or 0
	local period = tonumber(self.variables["DISCORD_UNLISTED_PERIOD"]) or 600
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
	discord.send(premature, self, {
		username = "BunkerWeb",
		embeds = {
			{
				title = "Unlisted IP "
					.. ip
					.. " denied "
					.. tostring(count)
					.. " times within "
					.. tostring(period)
					.. "s",
				description = "IP not in DISCORD_ALERT_IPS. No more notification about this IP until the period ends.",
				timestamp = embedTimestamp,
				color = 0xE67E22,
				provider = {
					name = "BunkerWeb",
					url = "https://github.com/bunkerity/bunkerweb",
				},
				author = {
					name = "BunkerWeb's Discord plugin",
					url = "https://github.com/bunkerity/bunkerweb",
					icon_url = "https://raw.githubusercontent.com/bunkerity/bunkerweb-plugins/main/logo.png",
				},
				fields = {
					{
						name = "Reason",
						value = reason,
						inline = true,
					},
				},
			},
		},
	})
end

function discord.send(premature, self, data)
	local httpc, err = http_new()
	if not httpc then
		self.logger:log(ERR, "can't instantiate http object : " .. err)
	end
	local res, err_http = httpc:request_uri(self.variables["DISCORD_WEBHOOK_URL"], {
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
	if self.variables["DISCORD_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
		self.logger:log(WARN, "Discord API is rate-limiting us, retrying in " .. res.headers["Retry-After"] .. "s")
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

function discord:log_default()
	-- Check if discord is activated
	local check, err = has_variable("USE_DISCORD", "yes")
	if check == nil then
		return self:ret(false, "error while checking variable USE_DISCORD (" .. err .. ")")
	end
	if not check then
		return self:ret(true, "Discord plugin not enabled")
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

function discord:api()
	if self.ctx.bw.uri == "/discord/stats" and self.ctx.bw.request_method == "GET" then
		return self:ret(true, self:get_stats(), HTTP_OK)
	end
	if self.ctx.bw.uri == "/discord/ping" and self.ctx.bw.request_method == "POST" then
		-- Check discord connection
		local check, err = has_variable("USE_DISCORD", "yes")
		if check == nil then
			return self:ret(true, "error while checking variable USE_DISCORD (" .. err .. ")")
		end
		if not check then
			return self:ret(true, "Discord plugin not enabled")
		end

		-- Send test data to discord webhook
		local data = {
			username = "BunkerWeb",
			embeds = {
				{
					title = "Test message",
					description = "This is a test message sent by BunkerWeb's Discord plugin",
					color = 0x125678,
					provider = {
						name = "BunkerWeb",
						url = "https://github.com/bunkerity/bunkerweb",
					},
					author = {
						name = "BunkerWeb's Discord plugin",
						url = "https://github.com/bunkerity/bunkerweb",
						icon_url = "https://raw.githubusercontent.com/bunkerity/bunkerweb-plugins/main/logo.png",
					},
				},
			},
		}
		-- Send request
		local httpc
		httpc, err = http_new()
		if not httpc then
			self.logger:log(ERR, "can't instantiate http object : " .. err)
		end
		local res, err_http = httpc:request_uri(self.variables["DISCORD_WEBHOOK_URL"], {
			method = "POST",
			headers = {
				["Content-Type"] = "application/json",
			},
			body = encode(data),
		})
		httpc:close()
		if not res then
			return self:ret(true, "error while sending request : " .. err_http, HTTP_INTERNAL_SERVER_ERROR)
		end
		if self.variables["DISCORD_RETRY_IF_LIMITED"] == "yes" and res.status == 429 and res.headers["Retry-After"] then
			return self:ret(
				true,
				"Discord API is rate-limiting us, retry in " .. res.headers["Retry-After"] .. "s",
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

return discord
