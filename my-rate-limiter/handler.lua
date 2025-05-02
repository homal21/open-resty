-- Không sử dụng base_plugin nữa
local redis = require "resty.redis"
local timestamp = require "kong.tools.timestamp"

-- Khai báo plugin
local CustomRateLimiter = {}

-- Đặt priority và version
CustomRateLimiter.PRIORITY = 901
CustomRateLimiter.VERSION = "1.0.0"

local VIOLATIONS_KEY_PREFIX = "custom_rate_limit_violations:"
local BANNED_KEY_PREFIX = "custom_rate_limit_banned:"
local BAN_DURATION = 60  -- 1 giờ tính bằng giây

-- Các hàm xử lý Redis
local function get_redis_connection(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    kong.log.err("Failed to connect to Redis: ", err)
    return nil, err
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if not ok then
      kong.log.err("Failed to authenticate with Redis: ", err)
      return nil, err
    end
  end

  if conf.redis_database ~= 0 then
    local ok, err = red:select(conf.redis_database)
    if not ok then
      kong.log.err("Failed to select Redis database: ", err)
      return nil, err
    end
  end

  return red
end

local function is_ip_banned(red, key)
  local exists, err = red:exists(key)
  if err then
    kong.log.err("Error checking if IP is banned: ", err)
    return false
  end

  return exists == 1
end

local function increment_violations(red, key)
  local violations, err = red:incr(key)
  if err then
    kong.log.err("Error incrementing violations: ", err)
    return 0
  end

  -- Set expiration for violations counter
  red:expire(key, BAN_DURATION * 2)

  return violations
end

local function ban_ip(red, ban_key, violations_key, ip)
  red:setex(ban_key, BAN_DURATION, 1)
  red:del(violations_key)
  kong.log.notice("IP ", ip, " banned for ", BAN_DURATION, " seconds")
end

-- Hàm xử lý access phase - thay thế cho phương thức :access của BasePlugin
function CustomRateLimiter:access(conf)
  -- Get client IP
  local client_ip = kong.client.get_forwarded_ip()
  if not client_ip then
    client_ip = kong.client.get_ip()
  end

  -- Check if the IP is already banned
  local red, err = get_redis_connection(conf)
  if not red then
    return  -- If Redis connection fails, allow the request to proceed
  end

  local ban_key = BANNED_KEY_PREFIX .. client_ip
  if is_ip_banned(red, ban_key) then
    -- IP is banned, reject the request
    local ban_ttl = red:ttl(ban_key)
    kong.response.set_header("X-IP-Ban-Remaining", ban_ttl)
    kong.response.exit(403, { message = "IP blocked !!! Retry after " .. ban_ttl .. "second" })
  end


  -- Apply regular rate limiting
  local window_size = conf.window_size
  local current_time = ngx.time()
  local window_time = math.floor(current_time/ window_size) * window_size
--   local current_timestamp = timestamp.get_utc()
--   local periods = timestamp.get_timestamps(current_timestamp)


--   local window = nil
  local exceeded = false
  local rate_key = "ratelimit:" .. client_ip .. ":" .. window_time

--   for period, period_date in pairs(periods) do
--     local rate_key = "rate_limit:" .. client_ip .. ":" .. conf.window_size

    -- Check rate limit
  local count, err = red:get(rate_key)
  if err then
    kong.log.err("Error getting rate limit counter: ", err)
  else
    count = tonumber(count) or 0
    kong.log.err("COUNT: ", count)
  end

  if count >= conf.limit then
    exceeded = true
  else

      -- Increment counter
      local ok, err = red:incr(rate_key)
      if not ok then
        kong.log.err("Error incrementing rate limit counter: ", err)
      end
      local ttl = window_time + window_size - current_time
      kong.log.err("TTL: ", ttl)
      red:expire(rate_key, ttl)
  end

  -- Set headers
  kong.response.set_header("X-RateLimit-Limit", conf.limit)

  -- If rate limit exceeded, check/update violations counter
  if exceeded then
    local violations_key = VIOLATIONS_KEY_PREFIX .. client_ip
    local violations = increment_violations(red, violations_key)
    kong.log.err("violations: ", violations)
    if violations >= conf.max_violations then
      ban_ip(red, ban_key, violations_key, client_ip)
      kong.response.set_header("X-IP-Ban-Duration", BAN_DURATION)
      kong.response.exit(403, { message = "IP blocked in " .. BAN_DURATION })
    else
      kong.response.set_header("X-RateLimit-Violations", violations)
      kong.response.set_header("X-RateLimit-Remaining", 0)
      kong.response.exit(429, { message = "API limit. Violate " .. violations .. " in " .. conf.max_violations .. " will be blocked." })
    end
  else
    kong.response.set_header("X-RateLimit-Remaining", conf.limit - 1)
    kong.response.set_header("X-RateLimit-Reset", window_time + window_size - current_time)
  end

  -- Return connection to pool
  red:set_keepalive(10000, 100)
end

return CustomRateLimiter