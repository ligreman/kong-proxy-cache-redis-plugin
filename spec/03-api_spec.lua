local helpers = require "spec.helpers"
local cjson = require "cjson"


describe("Plugin: proxy-cache-redis", function()
  local bp
  local proxy_client, admin_client, cache_key, plugin1, route1

  setup(function()
    bp = helpers.get_db_utils(nil, nil, {"proxy-cache-redis"})

    route1 = assert(bp.routes:insert {
      hosts = { "route-1.com" },
    })
    plugin1 = assert(bp.plugins:insert {
      name = "proxy-cache-redis",
      route = { id = route1.id },
      config = {
        strategy = "memory",
        content_type = { "text/plain", "application/json" },
        memory = {
          dictionary_name = "kong",
        },
      },
    })

    -- an additional plugin does not interfere with the iteration in
    -- the global /proxy-cache API handler: regression test for
    -- https://github.com/Kong/kong-plugin-proxy-cache/issues/12
    assert(bp.plugins:insert {
      name = "request-transformer",
    })

    local route2 = assert(bp.routes:insert {
      hosts = { "route-2.com" },
    })

    assert(bp.plugins:insert {
      name = "proxy-cache-redis",
      route = { id = route2.id },
      config = {
        strategy = "memory",
        content_type = { "text/plain", "application/json" },
        memory = {
          dictionary_name = "kong",
        },
      },
    })

    assert(helpers.start_kong({
      plugins = "proxy-cache-redis,request-transformer",
      nginx_conf = "spec/fixtures/custom_nginx.template",
    }))

    if admin_client then
      admin_client:close()
    end
    if proxy_client then
      proxy_client:close()
    end

    admin_client = helpers.admin_client()
    proxy_client = helpers.proxy_client()
  end)

  teardown(function()
    helpers.stop_kong(nil, true)
  end)

  describe("(schema)", function()
    local body

    it("accepts an array of numbers as strings", function()
      local res = assert(admin_client:send {
        method = "POST",
        path = "/plugins",
        body = {
          name = "proxy-cache-redis",
          config = {
            strategy = "memory",
            memory = {
              dictionary_name = "kong",
            },
            response_code = {123, 200},
            cache_ttl = 600,
            request_method = { "GET" },
            content_type = { "text/json" },
          },
        },
        headers = {
          ["Content-Type"] = "application/json",
        },
      })
      body = assert.res_status(201, res)
    end)
    it("casts an array of response_code values to number types", function()
      local json = cjson.decode(body)
      for _, v in ipairs(json.config.response_code) do
        assert.is_number(v)
      end
    end)
    it("errors if response_code is an empty array", function()
      local res = assert(admin_client:send {
        method = "POST",
        path = "/plugins",
        body = {
          name = "proxy-cache-redis",
          config = {
            strategy = "memory",
            memory = {
              dictionary_name = "kong",
            },
            response_code = {},
            cache_ttl = 600,
            request_method = { "GET" },
            content_type = { "text/json" },
          },
        },
        headers = {
          ["Content-Type"] = "application/json",
        },
      })
      local body = assert.res_status(400, res)
      local json_body = cjson.decode(body)
      assert.same("length must be at least 1", json_body.fields.config.response_code)
    end)
    it("errors if response_code is a string", function()
      local res = assert(admin_client:send {
        method = "POST",
        path = "/plugins",
        body = {
          name = "proxy-cache-redis",
          config = {
            strategy = "memory",
            memory = {
              dictionary_name = "kong",
            },
            response_code = {},
            cache_ttl = 600,
            request_method = "GET",
            content_type = "text/json",
          },
        },
        headers = {
          ["Content-Type"] = "application/json",
        },
      })
      local body = assert.res_status(400, res)
      local json_body = cjson.decode(body)
      assert.same("length must be at least 1", json_body.fields.config.response_code)
    end)
    it("errors if response_code has non-numeric values", function()
      local res = assert(admin_client:send {
        method = "POST",
        path = "/plugins",
        body = {
          name = "proxy-cache-redis",
          config = {
            strategy = "memory",
            memory = {
              dictionary_name = "kong",
            },
            response_code = {true, "alo", 123},
            cache_ttl = 600,
            request_method = "GET",
            content_type = "text/json",
          },
        },
        headers = {
          ["Content-Type"] = "application/json",
        },
      })
      local body = assert.res_status(400, res)
      local json_body = cjson.decode(body)
      assert.same( { "expected an integer", "expected an integer" },
                   json_body.fields.config.response_code)
    end)
    it("errors if response_code has float value", function()
      local res = assert(admin_client:send {
        method = "POST",
        path = "/plugins",
        body = {
          name = "proxy-cache-redis",
          config = {
            strategy = "memory",
            memory = {
              dictionary_name = "kong",
            },
            response_code = {90},
            cache_ttl = 600,
            request_method = "GET",
            content_type = "text/json",
          },
        },
        headers = {
          ["Content-Type"] = "application/json",
        },
      })
      local body = assert.res_status(400, res)
      local json_body = cjson.decode(body)
      assert.same({ "value should be between 100 and 900" },
                   json_body.fields.config.response_code)
    end)
  end)
  describe("(API)", function()
    describe("DELETE", function()
      it("delete a cache entry", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])

        -- cache key is an md5sum of the prefix uuid, method, and $request
        local cache_key1 = res.headers["X-Cache-Key"]
        assert.matches("^[%w%d]+$", cache_key1)
        assert.equals(32, #cache_key1)
        cache_key = cache_key1

        res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Hit", res.headers["X-Cache-Status"])
        local cache_key2 = res.headers["X-Cache-Key"]
        assert.same(cache_key1, cache_key2)

        -- delete the key
        res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis/" .. plugin1.id .. "/caches/" .. cache_key,
        })
        assert.res_status(204, res)

        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])

        -- delete directly, having to look up all proxy-cache instances
        res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis/" .. cache_key,
        })
        assert.res_status(204, res)

        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])
      end)
      it("purge all the cache entries", function()
        -- make a `Hit` request to `route-1`
        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })
        assert.res_status(200, res)
        assert.same("Hit", res.headers["X-Cache-Status"])

        -- make a `Miss` request to `route-2`
        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-2.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])

        -- cache key is an md5sum of the prefix uuid, method, and $request
        local cache_key1 = res.headers["X-Cache-Key"]
        assert.matches("^[%w%d]+$", cache_key1)
        assert.equals(32, #cache_key1)

        -- make a `Hit` request to `route-1`
        res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-2.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Hit", res.headers["X-Cache-Status"])
        local cache_key2 = res.headers["X-Cache-Key"]
        assert.same(cache_key1, cache_key2)

        -- delete all the cache keys
        res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis",
        })
        assert.res_status(204, res)

        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])

        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-2.com",
          }
        })

        assert.res_status(200, res)
        assert.same("Miss", res.headers["X-Cache-Status"])
      end)
      it("delete a non-existing cache key", function()
        -- delete all the cache keys
        local res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis",
        })
        assert.res_status(204, res)

        local res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis/" .. plugin1.id .. "/caches/" .. "123",
        })
        assert.res_status(404, res)
      end)
      it("delete a non-existing plugins's cache key", function()
        -- delete all the cache keys
        local res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis",
        })
        assert.res_status(204, res)

        local res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis/" .. route1.id .. "/caches/" .. "123",
        })
        assert.res_status(404, res)
      end)
    end)
    describe("GET", function()
      it("get a non-existing cache", function()
        -- delete all the cache keys
        local res = assert(admin_client:send {
          method = "DELETE",
          path = "/proxy-cache-redis",
        })
        assert.res_status(204, res)

        local res = assert(admin_client:send {
          method = "GET",
          path = "/proxy-cache-redis/" .. plugin1.id .. "/caches/" .. cache_key,
        })
        assert.res_status(404, res)

        -- attempt to list an entry directly via cache key
        local res = assert(admin_client:send {
          method = "GET",
          path = "/proxy-cache-redis/" .. cache_key,
        })
        assert.res_status(404, res)
      end)
      it("get a existing cache", function()
        -- add request to cache
        local res = assert(proxy_client:send {
          method = "GET",
          path = "/get",
          headers = {
            host = "route-1.com",
          }
        })
        assert.res_status(200, res)

        local res = assert(admin_client:send {
          method = "GET",
          path = "/proxy-cache-redis/" .. plugin1.id .. "/caches/" .. cache_key,
        })
        local body = assert.res_status(200, res)
        local json_body = cjson.decode(body)
        assert.same(cache_key, json_body.headers["X-Cache-Key"])

        -- list an entry directly via cache key
        local res = assert(admin_client:send {
          method = "GET",
          path = "/proxy-cache-redis/" ..  cache_key,
        })
        local body = assert.res_status(200, res)
        local json_body = cjson.decode(body)
        assert.same(cache_key, json_body.headers["X-Cache-Key"])
      end)
    end)
  end)
end)
