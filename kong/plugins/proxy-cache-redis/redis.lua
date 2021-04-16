local cjson = require "cjson.safe"
local redis = require "resty.redis"

local ngx = ngx
local type = type

local function is_present(str)
    return str and str ~= "" and str ~= null
end

local _M = {}

-- Conecta a redis
local function red_connect(opts)
    local red, err_redis = redis:new()

    if err_redis then
        kong.log.err("error connecting to Redis: ", err_redis);
        return nil, err_redis
    end

    local redis_opts = {}
    -- use a special pool name only if database is set to non-zero
    -- otherwise use the default pool name host:port
    redis_opts.pool = opts.redis_database and opts.redis_host .. ":" .. opts.redis_port .. ":" .. opts.redis_database

    red:set_timeout(opts.redis_timeout)

    -- conecto
    local ok, err = red:connect(opts.redis_host, opts.redis_port, redis_opts)
    if not ok then
        kong.log.err("failed to connect to Redis: ", err)
        return nil, err
    end

    local times, err2 = red:get_reused_times()
    if err2 then
        kong.log.err("failed to get connect reused times: ", err2)
        return nil, err
    end

    if times == 0 then
        if is_present(opts.redis_password) then
            local ok3, err3 = red:auth(opts.redis_password)
            if not ok3 then
                kong.log.err("failed to auth Redis: ", err3)
                return nil, err
            end
        end

        if opts.redis_database ~= 0 then
            -- Only call select first time, since we know the connection is shared
            -- between instances that use the same redis database
            local ok4, err4 = red:select(opts.redis_database)
            if not ok4 then
                kong.log.err("failed to change Redis database: ", err4)
                return nil, err
            end
        end
    end

    return red
end

-- Obtiene un dato de Redis
function _M:fetch(conf, key)
    local red, err_redis = red_connect(conf)

    -- Compruebo si he conectado a Redis bien
    if not red then
        kong.log.err("failed to get the Redis connection: ", err_redis)
        return nil, "there is no Redis connection established"
    end

    if type(key) ~= "string" then
        return nil, "key must be a string"
    end

    -- retrieve object from shared dict
    local req_json, err = red:get(key)
    if req_json == ngx.null then
        if not err then
            -- devuelvo nulo pero diciendo que no está en la caché, no que haya habido error realmente
            -- habrá que guardar la respuesta entonces
            return nil, "request object not in cache"
        else
            return nil, err
        end
    end

    local ok, err2 = red:set_keepalive(10000, 100)
    if not ok then
        kong.log.err("failed to set Redis keepalive: ", err2)
        return nil, err2
    end

    -- decode object from JSON to table
    local req_obj = cjson.decode(req_json)

    if not req_obj then
        return nil, "could not decode request object"
    end

    return req_obj
end

-- Guarda un dato en Redis
function _M:store(conf, key, req_obj, req_ttl)
    local red, err_redis = red_connect(conf)

    -- Compruebo si he conectado a Redis bien
    if not red then
        kong.log.err("failed to get the Redis connection: ", err_redis)
        return nil, "there is no Redis connection established"
    end

    local ttl = req_ttl or conf.cache_ttl

    if type(key) ~= "string" then
        return nil, "key must be a string"
    end

    -- encode request table representation as JSON
    local req_json = cjson.encode(req_obj)
    if not req_json then
        return nil, "could not encode request object"
    end

    -- Hago efectivo el guardado
    -- inicio la transacción
    red:init_pipeline()
    -- guardo
    red:set(key, req_json)
    -- TTL
    red:expire(key, ttl)

    -- ejecuto la transacción
    local _, err = red:commit_pipeline()
    if err then
        kong.log.err("failed to commit the cache value to Redis: ", err)
        return nil, err
    end

    -- keepalive de la conexión: max_timeout, connection pool
    local ok, err2 = red:set_keepalive(10000, 100)
    if not ok then
        kong.log.err("failed to set Redis keepalive: ", err2)
        return nil, err2
    end

    return true and req_json or nil, err
end


-- Elimina una clave
function _M:purge(conf, key)
    local red, err_redis = red_connect(conf)

    -- Compruebo si he conectado a Redis bien
    if not red then
        kong.log.err("failed to get the Redis connection: ", err_redis)
        return nil, "there is no Redis connection established"
    end

    if type(key) ~= "string" then
        return nil, "key must be a string"
    end

    -- borro entrada de redis
    local deleted, err = red:del(key)
    if err then
        kong.log.err("failed to delete the key from Redis: ", err)
        return nil, err
    end

    local ok, err2 = red:set_keepalive(10000, 100)
    if not ok then
        kong.log.err("failed to set Redis keepalive: ", err2)
        return nil, err2
    end

    return true
end

-- Elimina todas las entradas de la base de datos
function _M:flush(conf)
    local red, err_redis = red_connect(conf)

    -- Compruebo si he conectado a Redis bien
    if not red then
        kong.log.err("failed to get the Redis connection: ", err_redis)
        return nil, "there is no Redis connection established"
    end

    -- aquí borro toda la cache de redis de forma asíncrona
    local flushed, err = red:flushdb("async")
    if err then
        kong.log.err("failed to flush the database from Redis: ", err)
        return nil, err
    end

    local ok, err2 = red:set_keepalive(10000, 100)
    if not ok then
        kong.log.err("failed to set Redis keepalive: ", err2)
        return nil, err2
    end

    return true
end

return _M
