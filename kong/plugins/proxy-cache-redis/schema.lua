return {
    name = "proxy-cache-redis",
    fields = {
        { config = {
            type = "record",
            fields = {
                { response_code = {
                    type = "array",
                    default = { 200, 301, 404 },
                    elements = { type = "integer", between = { 100, 900 } },
                    len_min = 1,
                    required = true,
                } },
                { request_method = {
                    type = "array",
                    default = { "GET", "HEAD" },
                    elements = {
                        type = "string",
                        one_of = { "HEAD", "GET", "POST", "PATCH", "PUT" },
                    },
                    required = true
                } },
                { allow_force_cache_header = {
                    type = "boolean",
                    default = false,
                    required = true,
                } },
                { content_type = {
                    type = "array",
                    default = { "text/plain", "application/json" },
                    elements = { type = "string" },
                    required = true,
                } },
                { cache_ttl = {
                    type = "integer",
                    default = 300,
                    required = true,
                    gt = 0,
                } },
                { cache_control = {
                    type = "boolean",
                    default = false,
                    required = true,
                } },
                { storage_ttl = {
                    type = "integer",
                    gt = 0,
                } },
                { vary_query_params = {
                    type = "array",
                    elements = { type = "string" },
                } },
                { vary_headers = {
                    type = "array",
                    elements = { type = "string" },
                } },
                { vary_body_json_fields = {
                    type = "array",
                    elements = { type = "string" },
                } },
                { redis_host = {
                    type = "string",
                    required = true,
                } },
                { redis_port = {
                    between = { 0, 65535 },
                    type = "integer",
                    default = 6379,
                } },
                { redis_password = {
                    type = "string",
                    len_min = 0,
                } },
                { redis_timeout = {
                    type = "number",
                    default = 2000,
                } },
                { redis_database = {
                    type = "integer",
                    default = 0,
                } },
            },
        }
        },
    },

    entity_checks = {
    },
}
