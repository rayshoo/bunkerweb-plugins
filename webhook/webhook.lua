local cjson = require("cjson")
local class = require("middleclass")
local http = require("resty.http")
local ipmatcher = require("resty.ipmatcher")
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
local tostring = tostring
local tonumber = tonumber
local encode = cjson.encode
local ipmatcher_new = ipmatcher.new
local shared_datastore = ngx.shared.datastore or ngx.shared.datastore_stream

local UNLISTED_COUNTER_KEY = "plugin_webhook_unlisted_count"

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

-- Counts denied requests from unlisted IPs and returns the count when the threshold is reached
function webhook:count_unlisted()
	local threshold = tonumber(self.variables["WEBHOOK_UNLISTED_THRESHOLD"]) or 0
	if threshold <= 0 then
		return nil
	end
	if not shared_datastore then
		self.logger:log(ERR, "shared dict datastore not found, can't count unlisted IPs")
		return nil
	end
	local period = tonumber(self.variables["WEBHOOK_UNLISTED_PERIOD"]) or 600
	-- The counter expires period seconds after the first denied request,
	-- so at most one notification is sent per period
	local count, err = shared_datastore:incr(UNLISTED_COUNTER_KEY, 1, 0, period)
	if not count then
		self.logger:log(ERR, "can't increment unlisted counter : " .. err)
		return nil
	end
	if count == threshold then
		return count, period
	end
	return nil
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
	local matcher = self:get_alert_ips_matcher()
	if matcher then
		local match, err = matcher:match(self.ctx.bw.remote_addr)
		if err then
			self.logger:log(ERR, "can't match IP " .. self.ctx.bw.remote_addr .. " : " .. err)
		end
		if not match then
			local count, period = self:count_unlisted()
			if not count then
				return self:ret(true, "IP not in WEBHOOK_ALERT_IPS")
			end
			local summary = {
				content = "```"
					.. tostring(count)
					.. " requests from IPs not in WEBHOOK_ALERT_IPS have been denied within "
					.. tostring(period)
					.. "s (last one : IP "
					.. self.ctx.bw.remote_addr
					.. " / reason = "
					.. reason
					.. "). No more notification about unlisted IPs until the period ends.```",
			}
			local hdr
			hdr, err = ngx_timer.at(0, self.send, self, summary)
			if not hdr then
				return self:ret(true, "can't create report timer : " .. err)
			end
			return self:ret(true, "scheduled timer for unlisted threshold")
		end
		prefix = "🚨 Denied request from a watched IP (WEBHOOK_ALERT_IPS)\n"
	end
	-- Compute data
	local data = {}
	data.content = prefix
		.. "```Denied request for IP "
		.. self.ctx.bw.remote_addr
		.. " (reason = "
		.. reason
		.. " / reason data = "
		.. encode(reason_data or {})
		.. ").\n\nRequest data :\n\n"
		.. ngx.var.request
		.. "\n"
	local headers, err = ngx_req.get_headers()
	if not headers then
		data.content = data.content .. "error while getting headers : " .. err
	else
		for header, value in pairs(headers) do
			data.content = data.content .. header .. ": " .. value .. "\n"
		end
	end
	data.content = data.content .. "```"
	-- Send request
	local hdr
	hdr, err = ngx_timer.at(0, self.send, self, data)
	if not hdr then
		return self:ret(true, "can't create report timer : " .. err)
	end
	return self:ret(true, "scheduled timer")
end

-- luacheck: ignore 212
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
