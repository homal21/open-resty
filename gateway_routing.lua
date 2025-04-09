local _M = {}
local http = require "resty.http"
local cjson = require "cjson"

local routes = {
    ["/api/hub"] = {
        upstream = "http://demosign.easyca.vn:8890",
        methods = { GET = true, POST = true, PUT = true, DELETE = true },
        rewrite = function(uri)
            if uri:match("^/api/hub/authenticate") then
                return uri:gsub("^/api/hub/authenticate", "/api/authorization/gettoken")
            else
                return uri:gsub("^/api/hub/", "/api/")
            end
        end
    },
    ["/api/easysign"] = {
        upstream = "http://demosign.easyca.vn:8080",
        methods = { GET = true, POST = true, PUT = true, DELETE = true },
        rewrite = function(uri)
            return uri:gsub("^/api/easysign/", "/api/")
        end
    }
}

-- Log chi tiết cho ELK
function _M.log_request_details(route, target_uri, start_time, response)
    local request_time = ngx.now() - start_time
    local status = response and response.status or 0

    local log_data = {
        timestamp = ngx.now() * 1000,  -- Milliseconds
        request_id = ngx.var.request_id or "",
        client_ip = ngx.var.remote_addr,
        method = ngx.req.get_method(),
        uri = ngx.var.uri,
        target_uri = target_uri or "",
        route = route.upstream or "{}",
        status = status,
        content_type = response and response.headers["Content-Type"] or "",
        request_time = request_time,
        response_size = response and #(response.body or "") or 0,
        user_agent = ngx.var.http_user_agent or ""
    }

    -- Log dữ liệu chi tiết cho ELK
    ngx.log(ngx.INFO, "API_GATEWAY_METRICS: " .. tostring(cjson.encode(log_data)))
end

function _M.find_route(uri, method)
    -- Đầu tiên thử khớp chính xác
    local route = routes[uri]
    if route and route.methods[method] then
        local target_uri = uri
        if route.rewrite then
            target_uri = route.rewrite(uri)
        end
        return route, target_uri
    end

    -- Sau đó thử khớp tiền tố cho các đường dẫn động
    for prefix, route_config in pairs(routes) do
        if uri:find(prefix, 1, true) == 1 then -- Kiểm tra xem URI có bắt đầu bằng tiền tố không
            if route_config.methods[method] then
                local target_uri = uri
                if route_config.rewrite then
                    target_uri = route_config.rewrite(uri)
                end
                return route_config, target_uri
            else
                return nil, "Phương thức không được phép"
            end
        end
    end

    return nil, "Không tìm thấy đường dẫn"
end

function _M.get_service_for_uri(uri)
    for prefix, route_config in pairs(routes) do
        if uri:find(prefix, 1, true) == 1 then
            return route_config.upstream
        end
    end
    return nil
end

function _M.route()
    local start_time = ngx.now()
    ngx.log(ngx.INFO, "Starting route function")

    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    ngx.log(ngx.INFO, "URI: ", uri, ", Method: ", method)

    -- Find matching route
    local route, target_uri = _M.find_route(uri, method)
    local err

    if not route then
        err = "Không tìm thấy đường dẫn"
        _M.log_request_details(nil, nil, start_time, nil)
        ngx.status = 404
        ngx.say(cjson.encode({
            error = err,
            request_id = ngx.var.request_id,
            timestamp = ngx.time()
        }))
        return nil, err
    end

    ngx.log(ngx.INFO, "Route found, upstream + target: ", route.upstream .. target_uri)

    -- Check if method is allowed
    local httpc = http.new()

    -- Thiết lập timeout
    httpc:set_timeout(5000)  -- 5 giây

    -- Get request body if needed
    local body = nil
    if method == "POST" or method == "PUT" then
        ngx.req.read_body()
        body = ngx.req.get_body_data()
        ngx.log(ngx.INFO, "Request body size: ", body and #body or 0)
    end

    -- Get headers and query params
    local headers = ngx.req.get_headers()
    local args = ngx.req.get_uri_args()

    -- Thêm headers theo dõi
    headers["X-Request-ID"] = ngx.var.request_id
    headers["X-Forwarded-For"] = ngx.var.remote_addr
    headers["X-Forwarded-Proto"] = ngx.var.scheme
    headers["X-Forwarded-Host"] = ngx.var.host

    ngx.log(ngx.INFO, "Making request to: ", route.upstream .. target_uri)

    -- Make the backend request
    local res, err = httpc:request_uri(route.upstream .. target_uri, {
        method = method,
        body = body,
        headers = headers,
        query = args,
        keepalive_timeout = 60,
        keepalive_pool = 10
    })

    if not res then
        ngx.log(ngx.ERR, "Backend request failed: ", err or "unknown error")
        _M.log_request_details(route, target_uri, start_time, {status = 500})
        return nil, "Failed to connect to backend: " .. (err or "unknown error")
    end

    -- Thêm thông tin upstream vào response headers
    if res.headers then
        res.headers["X-Upstream"] = route.upstream
    end

    -- Log thông tin kết quả
    _M.log_request_details(route, target_uri, start_time, res)

    -- Kiểm tra và xử lý phản hồi tùy theo loại nội dung
    if res.status >= 400 then
        ngx.log(ngx.WARN, "Backend returned error status: ", res.status)
    else
        ngx.log(ngx.INFO, "Backend request succeeded with status: ", res.status)
    end

    return res
end

return _M