local require = require
local cache_key = require "kong.plugins.proxy-cache-redis.cache_key"
local redis = require "kong.plugins.proxy-cache-redis.redis"
local tab_new = require("table.new")

local ngx = ngx
local kong = kong
local type = type
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local max = math.max
local floor = math.floor
local lower = string.lower
local concat = table.concat
local time = ngx.time
local resp_get_headers = ngx.resp and ngx.resp.get_headers
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_sub = ngx.re.gsub
local ngx_re_match = ngx.re.match
local parse_http_time = ngx.parse_http_time

local CACHE_VERSION = 1
local EMPTY = {}


-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
-- note content-length is not strictly hop-by-hop but we will be
-- adjusting it here anyhow
local hop_by_hop_headers = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailers"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["content-length"] = true,
}

local function overwritable_header(header)
    local n_header = lower(header)

    return not hop_by_hop_headers[n_header]
            and not ngx_re_match(n_header, "ratelimit-remaining")
end

local function parse_directive_header(h)
    if not h then
        return EMPTY
    end

    if type(h) == "table" then
        h = concat(h, ", ")
    end

    local t = {}
    local res = tab_new(3, 0)
    local iter = ngx_re_gmatch(h, "([^,]+)", "oj")

    local m = iter()
    while m do
        local _, err = ngx_re_match(m[0], [[^\s*([^=]+)(?:=(.+))?]], "oj", nil, res)
        if err then
            kong.log.err(err)
        end

        -- store the directive token as a numeric value if it looks like a number;
        -- otherwise, store the string value. for directives without token, we just
        -- set the key to true
        t[lower(res[1])] = tonumber(res[2]) or res[2] or true

        m = iter()
    end

    return t
end

local function req_cc()
    return parse_directive_header(ngx.var.http_cache_control)
end

local function res_cc()
    return parse_directive_header(ngx.var.sent_http_cache_control)
end

local function resource_ttl(res_cc)
    local max_age = res_cc["s-maxage"] or res_cc["max-age"]

    if not max_age then
        local expires = ngx.var.sent_http_expires

        -- if multiple Expires headers are present, last one wins
        if type(expires) == "table" then
            expires = expires[#expires]
        end

        local exp_time = parse_http_time(tostring(expires))
        if exp_time then
            max_age = exp_time - time()
        end
    end

    return max_age and max(max_age, 0) or 0
end

-- Comprueba si la petición es cacheble
local function cacheable_request(conf, cc)
    do
        -- check if is allowed the force cache, and if the header is present
        local forceHeader = kong.request.get_header("X-Proxy-Cache-Redis-Force")
        if conf.allow_force_cache_header and forceHeader == "true" then
            return true
        end

        -- check request method
        local method = kong.request.get_method()
        local method_match = false
        for i = 1, #conf.request_method do
            if conf.request_method[i] == method then
                method_match = true
                break
            end
        end

        if not method_match then
            return false
        end
    end

    -- check for explicit disallow directives
    if conf.cache_control and (cc["no-store"] or cc["no-cache"] or ngx.var.authorization) then
        return false
    end

    return true
end

-- Comprueba si la respuesta es cacheable
local function cacheable_response(conf, cc)
    do
        local status = kong.response.get_status()
        local status_match = false

        for i = 1, #conf.response_code do
            if conf.response_code[i] == status then
                status_match = true
                break
            end
        end

        if not status_match then
            return false
        end
    end

    do
        local content_type = ngx.var.sent_http_content_type

        -- bail if we cannot examine this content type
        if not content_type or type(content_type) == "table" or content_type == "" then
            return false
        end

        local content_match = false
        for i = 1, #conf.content_type do
            if conf.content_type[i] == content_type then
                content_match = true
                break
            end
        end

        if not content_match then
            return false
        end
    end

    if conf.cache_control and (cc["private"] or cc["no-store"] or cc["no-cache"])
    then
        return false
    end

    if conf.cache_control and resource_ttl(cc) <= 0 then
        return false
    end

    return true
end


-- indicate that we should attempt to cache the response to this request
-- intentar guardar esta respuesta en caché
local function signal_cache_req(ctx, this_cache_key, cache_status)
    ctx.proxy_cache_redis = {
        cache_key = this_cache_key,
    }

    kong.response.set_header("X-Cache-Status", cache_status or "Miss")
end

-- Guardar un valor en el Store
local function store_cache_value(premature, conf, req_body, status, proxy_cache)

    local res = {
        status = status,
        headers = proxy_cache.res_headers,
        body = proxy_cache.res_body,
        body_len = #proxy_cache.res_body,
        timestamp = time(),
        ttl = proxy_cache.res_ttl,
        version = CACHE_VERSION,
        req_body = req_body,
    }

    local ttl = conf.storage_ttl or conf.cache_control and proxy_cache.res_ttl or conf.cache_ttl

    -- Almaceno la respuesta y sus datos en caché
    local ok, err = redis:store(conf, proxy_cache.cache_key, res, ttl)
    if not ok then
        kong.log.err(err)
    end
end

local ProxyCacheHandler = {
    VERSION = "2.0.1-0",
    PRIORITY = 902,
}


-- Executed upon every Nginx worker process’s startup.
function ProxyCacheHandler:init_worker()
end


-- Executed for every request from a client and before it is being proxied to the upstream service.
function ProxyCacheHandler:access(conf)
    kong.ctx.shared.plugin_configuration = conf

    local cc = req_cc()

    -- if we know this request is not cacheable, bail out
    if not cacheable_request(conf, cc) then
        kong.response.set_header("X-Cache-Status", "Bypass")
        return
    end

    -- Si en configuración me indican que he de tener en cuenta el body JSON
    local theBody = "";
    if (conf.vary_body_json_fields or EMPTY)[1] then
        -- Si el body es un JSON lo tengo en cuenta
        local body, err6, mimetype = kong.request.get_body('application/json')
        if not err6 and mimetype == 'application/json' then
            theBody = body
        end
    end


    -- construye la clave o hash de esta petición
    local consumer = kong.client.get_consumer()
    local route = kong.router.get_route()
    local uri = ngx_re_sub(ngx.var.request, "\\?.*", "", "oj")
    local the_cache_key = cache_key.build_cache_key(
            consumer and consumer.id,
            route and route.id,
            kong.request.get_method(),
            uri,
            kong.request.get_query(),
            kong.request.get_headers(),
            theBody,
            conf)

    kong.response.set_header("X-Cache-Key", the_cache_key)

    -- try to fetch the cached object from the computed cache key
    local ctx = kong.ctx.plugin
    -- Intenta recoger la caché correspondiente a esta key
    local res, err = redis:fetch(conf, the_cache_key)
    -- Si obtengo un error de que no consigo obtener la cache
    if err == "request object not in cache" then

        -- this request wasn't found in the data store, but the client only wanted
        -- cache data. see https://tools.ietf.org/html/rfc7234#section-5.2.1.7
        if conf.cache_control and cc["only-if-cached"] then
            return kong.response.exit(ngx.HTTP_GATEWAY_TIMEOUT)
        end

        ctx.req_body = kong.request.get_raw_body()

        -- this request is cacheable but wasn't found in the data store
        -- make a note that we should store it in cache later,
        -- and pass the request upstream
        return signal_cache_req(ctx, the_cache_key)

    elseif err then
        kong.log.err(err)
        return
    end

    -- Si la versión de los datos cacheados no es la misma que la actual, purgo (para evitar errores)
    if res.version ~= CACHE_VERSION then
        kong.log.notice("cache format mismatch, purging ", the_cache_key)
        redis:purge(conf, the_cache_key)
        return signal_cache_req(ctx, the_cache_key, "Bypass")
    end

    -- figure out if the client will accept our cache value
    if conf.cache_control then
        if cc["max-age"] and time() - res.timestamp > cc["max-age"] then
            return signal_cache_req(ctx, the_cache_key, "Refresh")
        end

        if cc["max-stale"] and time() - res.timestamp - res.ttl > cc["max-stale"]
        then
            return signal_cache_req(ctx, the_cache_key, "Refresh")
        end

        if cc["min-fresh"] and res.ttl - (time() - res.timestamp) < cc["min-fresh"]
        then
            return signal_cache_req(ctx, the_cache_key, "Refresh")
        end

    else
        -- don't serve stale data; res may be stored for up to `conf.storage_ttl` secs but served only for conf.cache_ttl
        -- no servir datos obsoletos; se guardará res los segundos indicados en conf.storage_ttl
        -- pero sólo se sirven durante conf.cache_ttl
        if time() - res.timestamp > conf.cache_ttl then
            return signal_cache_req(ctx, the_cache_key, "Refresh")
        end
    end

    -- we have cache data yo!
    -- expose response data for logging plugins
    local response_data = {
        res = res,
        req = {
            body = res.req_body,
        },
        server_addr = ngx.var.server_addr,
    }

    kong.ctx.shared.proxy_cache_hit = response_data

    local nctx = ngx.ctx
    nctx.proxy_cache_hit = response_data
    nctx.KONG_PROXIED = true

    for k in pairs(res.headers) do
        if not overwritable_header(k) then
            res.headers[k] = nil
        end
    end

    res.headers["Age"] = floor(time() - res.timestamp)
    res.headers["X-Cache-Status"] = "Hit"

    return kong.response.exit(res.status, res.body, res.headers)
end


-- Executed when all response headers bytes have been received from the upstream service.
function ProxyCacheHandler:header_filter(conf)
    local ctx = kong.ctx.plugin
    local proxy_cache = ctx.proxy_cache_redis
    -- don't look at our headers if
    -- a) the request wasn't cacheable, or
    -- b) the request was served from cache
    if not proxy_cache then
        return
    end

    local cc = res_cc()

    -- if this is a cacheable request, gather the headers and mark it so
    if cacheable_response(conf, cc) then
        proxy_cache.res_headers = resp_get_headers(0, true)
        proxy_cache.res_ttl = conf.cache_control and resource_ttl(cc) or conf.cache_ttl
    else
        kong.response.set_header("X-Cache-Status", "Bypass")
        ctx.proxy_cache_redis = nil
    end

    -- TODO handle Vary header
end


-- Executed for each chunk of the response body received from the upstream service. Since the response is streamed back to the client,
-- it can exceed the buffer size and be streamed chunk by chunk. hence this method can be called multiple times if the response is large.
function ProxyCacheHandler:body_filter(conf)
    local ctx = kong.ctx.plugin
    local proxy_cache = ctx.proxy_cache_redis
    if not proxy_cache then
        return
    end

    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    proxy_cache.res_body = (proxy_cache.res_body or "") .. (chunk or "")

    if eof then
        -- Retardo el guardado ya que en body_filter no puedo hacer conexiones cosocket que son las necesarias para conectar a redis
        ngx.timer.at(0, store_cache_value, conf, ctx.req_body, kong.response.get_status(), proxy_cache)
    end
end

return ProxyCacheHandler
