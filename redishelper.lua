local redis = require "resty.redis"

local _M = {}

function _M.connect()
    local red = redis:new()
    red:set_timeout(1000)  -- Timeout 1 giây

    local ok, err = red:connect("redis-server", 6379)
    if not ok then
        ngx.log(ngx.ERR, "Redis connection failed: ", err)
        return nil, err
    end

    return red
end

function _M.set_token(username, service, token, ttl)
    local red, err = _M.connect()
    if not red then
        return nil, err
    end

    local key = username .. ":" .. service
    ngx.log(ngx.ERR, "🔹 Storing token for ", key)
    local ok, err = red:set(key, token)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set token: ", err)
        return nil, err
    end

    red:expire(key, ttl)
    red:set_keepalive(1000000, 100)

    ngx.log(ngx.NOTICE, "Token stored successfully for ", username)
    return true
end

function _M.get_token(key)
    local red, err = _M.connect()
    if not red then
        return nil, err
    end

    local count, err = red:get(key)

    if count == ngx.null then
        return nil, "Token not found"
    end

    ngx.log(ngx.ERR, "access token: ", count)
    red:set_keepalive(1000000, 100)

    return count, nil
end

function _M.incr_and_expire(key, limit, expire_time)
    local red, err = _M.connect()
    if not red then
        return nil, err
    end
    local count, err = red:get(key)
    if count == ngx.null then
        count = 0
    else
        count = tonumber(count)
    end

    if count >= limit then
        ngx.log(ngx.WARN, "Rate limit exceeded for key: ", key)
    end
    local new_count, err = red:incrby(key, 1)
    if not new_count then
        ngx.log(ngx.ERR, "Failed to increment key: ", err)
        return nil, err
    end

    if count == 0 then
        red:expire(key, expire_time)
    end

    red:set_keepalive(1000000, 100)

    ngx.log(ngx.NOTICE, "Rate count for ", key, ": ", new_count)
    return new_count, nil
end

-- Add a function to add an IP to the blacklist
function _M.add_to_blacklist(ip)
    local red, err = _M.connect()
    if not red then
        return nil, err
    end

    local ok, err = red:sadd("ip_blacklist", ip)
    if not ok then
        ngx.log(ngx.ERR, "Failed to add IP to blacklist: ", err)
        return nil, err
    end

    -- Also add to shared dict for immediate effect
    ngx.shared.ip_blacklist:set(ip, true)

    red:set_keepalive(1000000, 100)
    ngx.log(ngx.WARN, "Added IP to blacklist: ", ip)
    return true
end

-- Check if an IP has exceeded the violation threshold
function _M.check_violations(ip, threshold)
    local red, err = _M.connect()
    if not red then
        return nil, err
    end

    local key = "violations:" .. ip
    local count, err = red:get(key)

    if count == ngx.null then
        count = 0
    else
        count = tonumber(count)
    end

    local new_count, err = red:incrby(key, 1)
    if not new_count then
        ngx.log(ngx.ERR, "Failed to increment violations: ", err)
        return nil, err
    end

    -- Set expiry of 24 hours if first violation
    if count == 0 then
        red:expire(key, 86400)  -- 24 hours
    end

    red:set_keepalive(1000000, 100)

    return new_count >= threshold, new_count
end

return _M