local cjson = require "cjson.safe"
local redis = require "resty.redis"

local ngx          = ngx
local type         = type
local time         = ngx.time
local setmetatable = setmetatable


local _M = {}

-- TODO aquí creo la conexión a Redis
--- Create new memory strategy object
-- @table opts Strategy options: contains las variables de redis
function _M.new(opts)
  local red = redis:new()
  local redis_opts = {}

  red:set_timeout(opts.timeout)

  -- use a special pool name only if database is set to non-zero
  -- otherwise use the default pool name host:port
  redis_opts.pool = opts.database and
          opts.host .. ":" .. opts.port ..
                  ":" .. opts.database

  -- conecto
  local ok, err = red:connect(opts.host, opts.port, redis_opts)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    --return nil, err
    return setmetatable({red = nil, opts = opts, err = err}, {__index = _M,})
  end

  local times, err2 = red:get_reused_times()
  if err2 then
    kong.log.err("failed to get connect reused times: ", err2)
    --return nil, err
    return setmetatable({red = nil, opts = opts, err = err2}, {__index = _M,})
  end

  if times == 0 then
    if is_present(opts.password) then
      local ok3, err3 = red:auth(opts.password)
      if not ok3 then
        kong.log.err("failed to auth Redis: ", err3)
        --return nil, err
        return setmetatable({red = nil, opts = opts, err = err3}, {__index = _M,})
      end
    end

    if opts.database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database
      local ok4, err4 = red:select(opts.database)
      if not ok4 then
        kong.log.err("failed to change Redis database: ", err4)
        --return nil, err
        return setmetatable({red = nil, opts = opts, err = err4}, {__index = _M,})
      end
    end
  end

  local self = { red = red, opts = opts, err = nil, }

  return setmetatable(self, {__index = _M,})
end


--- Store a new request entity in Redis
-- @string key The request key
-- @table req_obj The request object, represented as a table containing
--   everything that needs to be cached
-- @int[opt] ttl The TTL for the request; if nil, use default TTL specified
--   at strategy instantiation time
function _M:store(key, req_obj, req_ttl)
  local ttl = req_ttl or self.opts.ttl
  local red = self.red

  -- Compruebo si he conectado a Redis bien
  if not red then
    return nil, "there is no Redis connection established"
  end

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- encode request table representation as JSON
  local req_json = cjson.encode(req_obj)
  if not req_json then
    return nil, "could not encode request object"
  end

  -- TODO aquí guardo en redis
  -- Hago efectivo el guardado
  --local succ, err = self.dict:set(key, req_json, ttl)
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


--- Fetch a cached request
-- @string key The request key
-- @return Table representing the request
function _M:fetch(key)
  local red = self.red

  -- Compruebo si he conectado a Redis bien
  if not red then
    return nil, "there is no Redis connection established"
  end

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- TODO aquí obtengo entrada desde redis
  -- retrieve object from shared dict
  --local req_json, err = self.dict:get(key)
  local req_json, err = red:get(key)
  if not req_json then
    if not err then
      -- devuelvo nulo pero diciendo que no está en la caché, no que haya habido error realmente
      return nil, "request object not in cache"
    else
      return nil, err
    end
  end

  local ok, err2 = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("failed to set Redis keepalive: ", err2)
  end

  -- decode object from JSON to table
  local req_obj = cjson.decode(req_json)
  if not req_json then
    return nil, "could not decode request object"
  end

  return req_obj
end


--- Purge an entry from the request cache (borra una entrada)
-- @return true on success, nil plus error message otherwise
function _M:purge(key)
  local red = self.red

  -- Compruebo si he conectado a Redis bien
  if not red then
    return nil, "there is no Redis connection established"
  end

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- TODO borro entrada de redis
  --self.dict:delete(key)
  local deleted, err = red:del(key)
  if err then
    kong.log.err("failed to delete the key from Redis: ", err)
    return nil, err
  end

  local ok, err2 = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("failed to set Redis keepalive: ", err2)
  end

  return true
end


--- Reset TTL for a cached request
function _M:touch(key, req_ttl, timestamp)
  local red = self.red

  -- Compruebo si he conectado a Redis bien
  if not red then
    return nil, "there is no Redis connection established"
  end

  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  -- TODO cojo entrada de redis
  -- check if entry actually exists
  --local req_json, err = self.dict:get(key)
  local req_json, err = red:get(key)
  if not req_json then
    if not err then
      return nil, "request object not in cache"

    else
      return nil, err
    end
  end

  local ok, err2 = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("failed to set Redis keepalive: ", err2)
  end

  -- decode object from JSON to table
  local req_obj = cjson.decode(req_json)
  if not req_obj then
    return nil, "could not decode request object"
  end

  -- refresh timestamp field
  req_obj.timestamp = timestamp or time()

  -- store it again to reset the TTL
  return _M:store(key, req_obj, req_ttl)
end


--- Marks all entries as expired and remove them from the memory
-- @param free_mem Boolean indicating whether to free the memory; if false,
--   entries will only be marked as expired
-- @return true on success, nil plus error message otherwise
function _M:flush(free_mem)
  local red = self.red

  -- Compruebo si he conectado a Redis bien
  if not red then
    return nil, "there is no Redis connection established"
  end

  local flushed, err = red:flush("async")
  if err then
    kong.log.err("failed to flush the database from Redis: ", err)
    return nil, err
  end

  -- TODO aquí borro toda la cache de redis
  -- mark all items as expired
  --self.dict:flush_all()
  -- flush items from memory
  --if free_mem then
  --  self.dict:flush_expired()
  --end

  local ok, err2 = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("failed to set Redis keepalive: ", err2)
  end

  return true
end

return _M
