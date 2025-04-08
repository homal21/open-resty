local _M = {}
local cjson = require "cjson"
local http = require "resty.http"

_M.services = {
    ["/hub"] = {
        name = "serviceHub",
        upstream = "serviceHub",
        auth_endpoint = "/api/authorization/gettoken",
        auth_path = "^/hub/authorization/gettoken/?$", -- Fixed to match actual path in config
        token_field = "accessToken"
    },
    ["/easysign"] = {
        name = "serviceSign",
        upstream = "serviceSign",
        auth_endpoint = "/api/authenticate",
        auth_path = "^/easysign/authenticate/?$", -- Fixed to match expected path
        token_field = "accessToken"
    }
}

function _M.get_service_for_path(path)
    for prefix, service in pairs(_M.services) do
        if string.sub(path, 1, #prefix) == prefix then
            return service
        end
    end
    return nil
end

function _M.is_auth_endpoint(path)
    for _, service in pairs(_M.services) do
        if ngx.re.match(path, service.auth_path, "jo") then
            return true, service
        end
    end
    return false, nil
end

function _M.authenticate(service, credentials)
    local redis_helper = require "redishelper"

    -- Validate inputs
    if not service or not credentials or not credentials.username then
        return nil, "Invalid service or credentials"
    end

    -- Check if we have a cached token
    local key = credentials.username .. ":" .. service.name
    local cached_token, err = redis_helper.get_token(key)

    if cached_token then
        ngx.log(ngx.INFO, "Using cached token for user ", credentials.username,
                " and service ", service.name)
        return { [service.token_field] = cached_token }
    end

    -- No cached token, authenticate with the service
    local upstream_url = "http://" .. service.upstream .. service.auth_endpoint
    ngx.log(ngx.INFO, "Authenticating with ", upstream_url)

    local httpc = http.new()
    local res, err = httpc:request_uri(upstream_url, {
        method = "POST",
        body = cjson.encode(credentials),
        headers = { ["Content-Type"] = "application/json" }
    })

    if not res then
        return nil, "Error calling authentication service: " .. (err or "unknown error")
    end

    if res.status ~= 200 then
        return nil, "Authentication failed with status: " .. res.status
    end

    -- Parse the response
    local body = cjson.decode(res.body)

    if not body or not body[service.token_field] then
        return nil, "Invalid authentication response: missing token"
    end

    -- Cache the token
    local token = body[service.token_field]
    local success, err = redis_helper.set_token(
            credentials.username,
            service.name,
            token,
            3600  -- 1 hour expiry
    )

    if not success then
        ngx.log(ngx.ERR, "Failed to store token: ", err)
        -- Continue anyway since we have the token
    end

    return body
end

-- Verify token for a specific service
function _M.verify_token(service, username, token)
    local redis_helper = require "redishelper"

    if not service or not username or not token then
        return false, "Missing service, username, or token"
    end

    -- Get the cached token
    local key = username .. ":" .. service.name
    local cached_token, err = redis_helper.get_token(key)

    if not cached_token then
        return false, "No token found for user and service"
    end

    -- Simple matching - in a production system, you might want
    -- to validate with the service or check JWT claims
    if cached_token ~= token then
        return false, "Token mismatch"
    end

    return true
end

-- Handle an authentication request
function _M.handle_auth_request()
    local path = ngx.var.uri
    local is_auth, service = _M.is_auth_endpoint(path)

    if not is_auth or not service then
        ngx.status = 404
        ngx.say("Invalid authentication endpoint")
        return
    end

    -- Read credentials from request body
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()

    if not body_data then
        ngx.status = 400
        ngx.say("Missing request body")
        return
    end

    local credentials
    local success, err = pcall(function()
        credentials = cjson.decode(body_data)
    end)

    if not success or not credentials or not credentials.username then
        ngx.status = 400
        ngx.say("Invalid request: Missing or malformed credentials")
        return
    end

    -- Authenticate with the service
    local auth_result, err = _M.authenticate(service, credentials)

    if not auth_result then
        ngx.status = 401
        ngx.say("Authentication failed: " .. (err or "unknown error"))
        return
    end

    -- Return the auth response to the client
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(auth_result))
end

-- Handle routing for a regular request
function _M.handle_routing_request()
    local path = ngx.var.uri
    local service = _M.get_service_for_path(path)

    if not service then
        ngx.status = 404
        ngx.say("Service not found for path: " .. path)
        return ngx.exit(404)
    end

    -- Check for authentication header
    local auth_header = ngx.req.get_headers()["Authorization"]
    if not auth_header or not auth_header:match("^Bearer ") then
        ngx.log(ngx.WARN, "Missing or invalid Authorization header")
        ngx.status = 401
        ngx.header["WWW-Authenticate"] = "Bearer"
        ngx.say("Authentication required")
        return ngx.exit(401)
    end

    -- Extract token
    local token = auth_header:match("Bearer%s+(.+)")

    -- Get username from header or request
    local username = ngx.req.get_headers()["X-Username"]

    if not username then
        -- Alternative way to get username, depends on your authentication design
        -- This could be extracted from a JWT token, or from a query parameter, etc.
        username = ngx.req.get_uri_args()["username"]
    end

    if not username then
        ngx.status = 400
        ngx.say("Missing username identifier")
        return ngx.exit(400)
    end

    -- Verify the token
    local is_valid, err = _M.verify_token(service, username, token)

    if not is_valid then
        ngx.log(ngx.WARN, "Invalid token: ", err)
        ngx.status = 401
        ngx.say("Invalid or expired token")
        return ngx.exit(401)
    end

    -- If we get here, token is valid
    -- Set the upstream variable for nginx to use
    ngx.var.target_upstream = service.upstream

    -- You could add additional headers or transformations here if needed
    -- For example, to pass the username to the backend service:
    ngx.req.set_header("X-Authenticated-User", username)

    -- Optionally log the successful routing
    ngx.log(ngx.INFO, "Routing request to ", service.upstream, " for user ", username)

    -- The actual proxying happens in the nginx config via proxy_pass
    return
end

return _M