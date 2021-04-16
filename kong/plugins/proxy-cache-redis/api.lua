local redis = require  "kong.plugins.proxy-cache-redis.redis"
local kong = kong

return {
    ["/plugins/:plugin_id/proxy-cache-redis"] = {

        DELETE = function(self)
            -- Busco el plugin
            local plugin, errp = kong.db.plugins:select({ id = self.params.plugin_id })

            if errp then
                kong.log.err("Error retrieving the plugin: " .. errp)
                return nil
            end

            if not plugin then
                kong.log.err("Could not find plugin.")
                return nil
            end

            local ok, err = redis:flush(plugin.config)
            if not ok then
                return kong.response.exit(500, { message = err })
            end

            return kong.response.exit(204)
        end
    },
    ["/plugins/:plugin_id/proxy-cache-redis/:cache_key"] = {

        GET = function(self)
            -- Busco el plugin
            local plugin, errp = kong.db.plugins:select({ id = self.params.plugin_id })

            if errp then
                kong.log.err("Error retrieving the plugin: " .. errp)
                return nil
            end

            if not plugin then
                kong.log.err("Could not find plugin.")
                return nil
            end

            local cache_val, err = redis:fetch(plugin.config, self.params.cache_key)
            if err and err ~= "request object not in cache" then
                return kong.response.exit(500, err)
            end

            if cache_val then
                return kong.response.exit(200, cache_val)
            end

            -- fell through, not found
            return kong.response.exit(404)
        end,

        DELETE = function(self)
            -- Busco el plugin
            local plugin, errp = kong.db.plugins:select({ id = self.params.plugin_id })

            if errp then
                kong.log.err("Error retrieving the plugin: " .. errp)
                return nil
            end

            if not plugin then
                kong.log.err("Could not find plugin.")
                return nil
            end

            local cache_val, err = redis:fetch(plugin.config, self.params.cache_key)
            if err and err ~= "request object not in cache" then
                return kong.response.exit(500, err)
            end

            if cache_val then
                local _, err2 = redis:purge(plugin.config, self.params.cache_key)
                if err2 then
                    return kong.response.exit(500, err2)
                end

                return kong.response.exit(204)
            end

            -- fell through, not found
            return kong.response.exit(404)
        end,
    }
}
