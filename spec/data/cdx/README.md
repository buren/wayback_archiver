# CDX response fixtures

These fixtures preserve response shapes observed from the public Wayback CDX
endpoint. `success.json` is based on a real CNN CDX record. `blocked_site.txt`
is the body of a recorded HTTP 403 response for an administratively blocked
URL; `blocked_by_robots.txt` preserves the corresponding robots-policy error
shape. `malformed.json` represents the JSON object shape occasionally returned
by an API or proxy error instead of the requested row array.

The successful record and blocked response were cross-checked against the
EDGI `wayback` project's recorded fixtures. They are kept as static data so
the test suite never contacts the live Wayback service.
