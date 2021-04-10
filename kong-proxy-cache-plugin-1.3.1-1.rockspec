package = "kong-proxy-cache-redis-redis-plugin"
version = "1.3.1-1"

source = {
  url = "git://github.com/ligreman/kong-proxy-cache-redis-redis-plugin"
}

supported_platforms = {"linux", "macosx"}

description = {
  summary = "HTTP Redis Proxy Caching for Kong",
  license = "Apache 2.0",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.proxy-cache-redis.handler"]              = "kong/plugins/proxy-cache-redis/handler.lua",
    ["kong.plugins.proxy-cache-redis.cache_key"]            = "kong/plugins/proxy-cache-redis/cache_key.lua",
    ["kong.plugins.proxy-cache-redis.schema"]               = "kong/plugins/proxy-cache-redis/schema.lua",
    ["kong.plugins.proxy-cache-redis.api"]                  = "kong/plugins/proxy-cache-redis/api.lua",
    ["kong.plugins.proxy-cache-redis.strategies"]           = "kong/plugins/proxy-cache-redis/strategies/init.lua",
    ["kong.plugins.proxy-cache-redis.strategies.memory"]    = "kong/plugins/proxy-cache-redis/strategies/memory.lua",
  }
}
