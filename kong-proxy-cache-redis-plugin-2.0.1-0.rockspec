package = "kong-proxy-cache-redis-plugin"
version = "2.0.1-0"

source = {
  url = "git://github.com/ligreman/kong-proxy-cache-redis-plugin"
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
    ["kong.plugins.proxy-cache-redis.redis"]                = "kong/plugins/proxy-cache-redis/redis.lua",
  }
}
