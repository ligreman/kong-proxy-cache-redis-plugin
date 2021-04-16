# Kong proxy-cache-redis plugin

HTTP Proxy Redis Caching for Kong

## Synopsis

This plugin provides a reverse proxy cache implementation for Kong. It caches
response entities based on configurable response code and content type, as
well as request method. It can cache per-Consumer or per-API. Cache entities
are stored for a configurable period of time, after which subsequent requests
to the same resource will re-fetch and re-store the resource. Cache entities
can also be forcefully purged via the Admin API prior to their expiration
time.

It caches all responses in a Redis server.

## Cache TTL

TTL for serving the cached data. Kong sends a `X-Cache-Status` with value `Refresh` if the resource was found in cache, but could not satisfy the request, due to Cache-Control behaviors or reaching its hard-coded cache_ttl threshold.

## Storage TTL
Kong can store resource entities in the storage engine longer than the prescribed cache_ttl or Cache-Control values indicate. This allows Kong to maintain a cached copy of a resource past its expiration. This allows clients capable of using max-age and max-stale headers to request stale copies of data if necessary.

## Documentation

The plugin works in the same way as the official `proxy-cache` plugin, in terms of the way it generates the cache key, or how to assign it to a service or route. [Documentation for the Proxy Cache plugin](https://docs.konghq.com/hub/kong-inc/proxy-cache/)

## Configuration

|Parameter|Type|Required|Default|Description|
|---|---|---|---|---|
`name`|string|*required*| |The name of the plugin to use, in this case: `proxy-cache-redis`
`service.id`|string|*optional*| |The ID of the Service the plugin targets.
`route.id`|string|*optional*| |The ID of the Route the plugin targets.
`consumer.id`|string|*optional*| |The ID of the Consumer the plugin targets.
`enabled`|boolean|*optional*|true|Whether this plugin will be applied.
`config.response_code`|array of integers|*required*|[200, 301, 404]|Upstream response status code considered cacheable.
`config.request_method`|array of strings|*required*|["GET","HEAD"]|Downstream request methods considered cacheable.
`config.content_type`|array of strings|*required*|["text/plain", "application/json"]|Upstream response content types considered cacheable. The plugin performs an exact match against each specified value; for example, if the upstream is expected to respond with an application/json; charset=utf-8 content-type, the plugin configuration must contain said value or a Bypass cache status is returned.
`config.vary_headers`|array of strings|*optional*| |Relevant headers considered for the cache key. If undefined, none of the headers are taken into consideration.
`config.vary_query_params`|array of strings|*optional*| |Relevant query parameters considered for the cache key. If undefined, all params are taken into consideration.
`config.cache_ttl`|integer|*required*|300|TTL, in seconds, of cache resources.
`config.cache_control`|boolean|*required*|false|When enabled, respect the Cache-Control behaviors defined in RFC7234.
`config.storage_ttl`|integer|*required*| |Number of seconds to keep resources in the storage backend. This value is independent of cache_ttl or resource TTLs defined by Cache-Control behaviors. The resources may be stored for up to `storage_ttl` secs but served only for `cache_ttl`.
`config.redis_host`|string|*required*| |The hostname or IP address of the redis server.
`config.redis_port`|integer|*optional*|6379|The port of the redis server.
`config.redis_timeout`|integer|*optional*|2000|The timeout in milliseconds for the redis connection.
`config.redis_password`|string|*optional*| |The password (if required) to authenticate to the redis server.
`config.redis_database`|string|*optional*|0|The Redis database to use for caching the resources.
