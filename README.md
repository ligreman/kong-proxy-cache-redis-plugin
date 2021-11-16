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

## Kong Plugin Priority

This plugin has its priority modified to be executed before the rate-limit plungin. This way a request that is answered by the cache (a cache Hit), does not count in the rate-limit.

The original proxy-cache plugin from Kong Hub has a priority of 101. This plugin has a 902 priority, right before the rate-limit that has 901.

If you want a proxy-cache-redis plugin with the original priority so that it is executed after the rate-limit one, just modify the code and change the priority in handler.lua.

## Cache TTL

TTL for serving the cached data. Kong sends a `X-Cache-Status` with value:

- `Refresh` if the resource was found in cache, but could not satisfy the request, due to Cache-Control behaviors or reaching its hard-coded cache_ttl threshold.
- `ByPass` if the request was not cacheable.
- `Hit` if the request was cacheable, and a cached value was found and returned.
- `Miss` if the request was cacheable, and no cached value was found.

## Storage TTL

Kong can store resource entities in the storage engine longer than the prescribed cache_ttl or Cache-Control values indicate. This allows Kong to maintain a cached copy of a resource past its expiration. This allows clients capable of using max-age and max-stale headers to request stale copies of data if necessary.

## vary_body_json_fields

The plugin allows to pass JSON field/properties names to be considered in the cache key generation process. Simple string or number fields can be used, and will be taken into account in the cache hey hash creation.

## allow_force_cache_header

This boolean allows to force the cache mechanism even if the request method is not allowed to be cached by configuration. If the client sends a request with the header `X-Proxy-Cache-Redis-Force=true` then the request will bypass the method check, and can be elegible for caching. 

It also bypass the no-cache and no-store headers. The other checks, like response codes, will still be checked.

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
`config.allow_force_cache_header`|boolean|*required*|false|If true, clients can send the header "X-Proxy-Cache-Redis-Force" with value true, in order to force the request to be cached, even if its method is not among the request methods allowed to be cached.
`config.content_type`|array of strings|*required*|["text/plain", "application/json"]|Upstream response content types considered cacheable. The plugin performs an exact match against each specified value; for example, if the upstream is expected to respond with an application/json; charset=utf-8 content-type, the plugin configuration must contain said value or a Bypass cache status is returned.
`config.vary_headers`|array of strings|*optional*| |Relevant headers considered for the cache key. If undefined, none of the headers are taken into consideration.
`config.vary_body_json_fields`|array of strings|*optional*| |Relevant JSON fields in the body of the request, to be considered for the cache key. If undefined, none of the fields in the body are taken into consideration. Note: only works on  string or number fields, not on fields containing arrays or objects.
`config.vary_query_params`|array of strings|*optional*| |Relevant query parameters considered for the cache key. If undefined, all params are taken into consideration.
`config.cache_ttl`|integer|*required*|300|TTL, in seconds, of cache resources. May be overriden if `cache-control` is true and the client sends `s-maxage` or `max-age` in Cache-Control headers. 
`config.cache_control`|boolean|*required*|false|When enabled, respect the Cache-Control behaviors defined in RFC7234. It allows the use of the header Cache-Control with its values (no-store, no-cache, private, only-if-cached, max-age...). Read more info below.
`config.storage_ttl`|integer|*required*| |Number of seconds to keep resources in the storage backend. This value is independent of cache_ttl or resource TTLs defined by Cache-Control behaviors. The resources may be stored for up to `storage_ttl` secs but served only for `cache_ttl`.
`config.redis_host`|string|*required*| |The hostname or IP address of the redis server.
`config.redis_port`|integer|*optional*|6379|The port of the redis server.
`config.redis_timeout`|integer|*optional*|2000|The timeout in milliseconds for the redis connection.
`config.redis_password`|string|*optional*| |The password (if required) to authenticate to the redis server.
`config.redis_database`|string|*optional*|0|The Redis database to use for caching the resources.

## Cache-Control header

When `cache-control` is true in the configuration of the plugin, it reads the following Cache-Control headers:

- `no-cache` or `no-store`
    - This plugin manages both values the same way. A request with any (or both) of these Cache-Control header values, will not be cached or stored.
- `private`
    - The response will not be cached, but the server may answer with a previously cached response. 
- `max-age=<seconds>`
    - The maximum amount of time a resource is considered fresh. Unlike Expires, this directive is relative to the time of the request.
- `max-stale[=<seconds>]`
    - Indicates the client will accept a stale response. An optional value in seconds indicates the upper limit of staleness the client will accept.
- `min-fresh=<seconds>`
  - Indicates the client wants a response that will still be fresh for at least the specified number of seconds.
- `only-if-cached`
  - Set by the client to indicate "do not use the network" for the response. The cache should either respond using a stored response, or respond with a 504 status code.



Example of headers:
```
Cache-Control: max-age=<seconds>
Cache-Control: max-stale[=<seconds>]
Cache-Control: min-fresh=<seconds>
Cache-Control: no-cache
Cache-Control: no-store
```

More info: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control
