# Save Page Now 2 (SPN2) Public API Docs (Draft)

Vangelis Banos — updated: 2025-10-22

Original: [https://docs.google.com/document/d/1Nsv52MvSjbLb2PCpHlat0gkzw0EvtSgpKHu4mk0MnrA/edit?tab=t.0#heading=h.1gmodju1d6p0](https://docs.google.com/document/d/1Nsv52MvSjbLb2PCpHlat0gkzw0EvtSgpKHu4mk0MnrA/edit?tab=t.0#heading=h.1gmodju1d6p0)

Changelog: [https://docs.google.com/document/d/19RJsRncGUw2qHqGGg9lqYZYf7KKXMDL1Mro5o1Qw6QI/edit#](https://docs.google.com/document/d/19RJsRncGUw2qHqGGg9lqYZYf7KKXMDL1Mro5o1Qw6QI/edit#)

## Glossary

- **Capture**: A record in the Wayback Machine that can be accessed like: `http://web.archive.org/web/20051231203615/http://www.bbc.co.uk/`
- **Timestamp**: A datetime format used in the Wayback Machine: `YYYYMMDDHHMMSS` (example: `20051231203615`)
- **Embeds**: Components of a web page (images, CSS, JS, etc.). When we capture a web page, we also try to capture its embeds and return them with the capture result.
- **Outlinks**: Links found inside the capture. We return them with the capture result.

## Basic API Reference

The Save Page Now 2 (SPN2) API enables you to make a capture request and then check its progress with a status request.

### Capture request

SPN2 runs on `https://web.archive.org/save` and requires authentication using one of these methods:

1. **S3 API Keys (preferred)**: Get keys at `https://archive.org/account/s3.php`. Use HTTP header `Authorization: LOW <accesskey>:<secret>`.
2. **Cookies**: Use cookies `logged-in-sig` and `logged-in-user` from a logged-in browser session on `https://archive.org`.

To capture a page, use an HTTP `POST` or `GET`.

#### POST example

```bash
curl -X POST \
	-H "Accept: application/json" \
	-H "Authorization: LOW myaccesskey:mysecret" \
	-d 'url=http://brewster.kahle.org/' \
	https://web.archive.org/save
```

#### GET example (cookie auth)

```bash
curl -X GET \
	-H "Accept: application/json" \
	--cookie "logged-in-sig=xxx;logged-in-user=user1%40archive.org;" \
	https://web.archive.org/save/http://brewster.kahle.org/
```

#### Additional capture request options (HTTP POST required)

Important: Anything other than `"1"` or `"on"` is considered **off**. Values like `"01"` or `"True"` mean **off**.

| Parameter | Description |
| --- | --- |
| capture_all=1 | Capture a web page even with errors (HTTP 4xx/5xx). Default is to capture only HTTP 200. |
| capture_outlinks=1 | Capture outlinks automatically (also applies to PDF, JSON, RSS, MRSS). |
| capture_screenshot=1 | Capture a full-page screenshot (PNG). Stored as a separate capture. |
| delay_wb_availability=1 | Capture becomes available in Wayback after ~12 hours instead of immediately (reduces load). |
| force_get=1 | Force simple HTTP GET capture. Otherwise SPN2 may HEAD first to decide between browser vs GET. |
| skip_first_archive=1 | Skip checking whether this is a “first capture”. Speeds up captures. |
| if_not_archived_within=&lt;timedelta&gt; | Capture only if latest existing Archive capture is older than the given limit (e.g. 3d 5h 20m or 120). Default limit: 45 min. |
| if_not_archived_within=&lt;timedelta1&gt;,&lt;timedelta2&gt; | Two limits: first applies to main URL; second applies to outlinks. |
| outlinks_availability=1 | Return last-capture timestamp for outlinks. |
| email_result=1 | Send an email report of captured URLs. |
| js_behavior_timeout=&lt;N&gt; | Run JS behaviors for N seconds after page load. Default: 5s; max: 30s. Use js_behavior_timeout=0 to skip JS if not needed. |
| capture_cookie=&lt;XXX&gt; | Provide extra cookie value when capturing. |
| use_user_agent=&lt;XXX&gt; | Use a custom HTTP User-Agent. |
| target_username=&lt;XXX&gt;
target_password=&lt;YYY&gt; | Provide credentials for target site login forms. |

Example (POST with outlinks + capture_all):

```bash
curl -X POST -H "Accept: application/json" \
	-d 'url=http://brewster.kahle.org/&capture_outlinks=1&capture_all=1' \
	-H "Authorization: LOW myaccesskey:mysecret" \
	https://web.archive.org/save
```

A capture request may return:

```json
{"url":"http://brewster.kahle.org/", "job_id":"ac58789b-f3ca-48d0-9ea6-1d1225e98695"}
```

### Status request

You can query the status of one or multiple captures.

#### GET example

```bash
curl -X GET \
	-H "Accept: application/json" \
	-H "Authorization: LOW myaccesskey:mysecret" \
	https://web.archive.org/save/status/ac58789b-f3ca-48d0-9ea6-1d1225e98695
```

#### POST example (cookie auth)

```bash
curl -X POST \
	-H "Accept: application/json" \
	-d 'job_id=ac58789b-f3ca-48d0-9ea6-1d1225e98695' \
	--cookie "logged-in-sig=AAAAAAAAAA;logged-in-user=user1%40archive.org;" \
	https://web.archive.org/save/status
```

Successful response example:

```json
{
	"status":"success",
	"job_id":"ac58789b-f3ca-48d0-9ea6-1d1225e98695",
	"original_url":"http://brewster.kahle.org/",
	"screenshot":"http://web.archive.org/screenshot/http://brewster.kahle.org/",
	"timestamp":"20180326070330",
	"duration_sec":6.203,
	"resources":["..."],
	"outlinks": {"...": "..."}
}
```

Notes:

- `original_url` is the final URL after following redirects.
- `screenshot` is only included when `capture_screenshot=1`.

If `outlinks_availability=1` is used, outlinks look like:

```json
"outlinks": {
	"https://archive.org/": {"timestamp": "20180102005040"},
	"https://other.com": {"timestamp": "20190102005040"},
	"https://other-not-captured.com": {"timestamp": null}
}
```

Pending example:

```json
{
	"status":"pending",
	"job_id":"e70f33c7-9eca-4c88-826d-26930564d7c8",
	"resources": ["..."]
}
```

Error example:

```json
{
	"status":"error",
	"exception":"[Errno -2] Name or service not known",
	"status_ext":"error:invalid-host-resolution",
	"job_id":"2546c79b-ec70-4bec-b78b-1941c42a6374",
	"message":"Couldn't resolve host for http://example5123.com.",
	"resources": []
}
```

## Error codes

`status_ext` contains more information on the specific error type.

| status_ext | Description |  |  |
| --- | --- | --- | --- |
| error:bad-gateway | Bad Gateway for URL (HTTP 502). | error:bad-request | Invalid request syntax (HTTP 401). |
| error:bandwidth-limit-exceeded | Bandwidth exceeded (HTTP 509). | error:blocked | Target site is blocking us (HTTP 999). |
| error:blocked-client-ip | Blocked clients listed in Spamhaus XBL/SBL; Tor exit nodes excluded. | error:blocked-url | URL is blocked by tracker-based block list. |
| error:browsing-timeout | Headless browser timeout. | error:capture-location-error | Created capture location not found (system error). |
| error:cannot-fetch | Cannot fetch due to system overload. | error:celery | Cannot start capture task. |
| error:filesize-limit | Cannot capture resources over 2GB. | error:ftp-access-denied | FTP access denied. |
| error:gateway-timeout | Target server timeout (HTTP 504). | error:http-version-not-supported | HTTP version not supported (HTTP 505). |
| error:internal-server-error | Internal server error. | error:invalid-url-syntax | Target URL syntax invalid. |
| error:invalid-server-response | Invalid target server response (headers/encoding/etc). | error:invalid-host-resolution | Could not resolve host. |
| error:job-failed | Capture failed due to system error. | error:method-not-allowed | Method disabled (HTTP 405). |
| error:not-implemented | Method not supported (HTTP 501). | error:no-browsers-available | No headless browsers available. |
| error:network-authentication-required | Network authentication required (HTTP 511). | error:no-access | Access forbidden (HTTP 403). |
| error:not-found | Not found (HTTP 404). | error:proxy-error | Proxy error. |
| error:protocol-error | Protocol error (possible cause: IncompleteRead). | error:read-timeout | Read timeout. |
| error:soft-time-limit-exceeded | Capture duration exceeded 45s and was terminated. | error:service-unavailable | Service unavailable (HTTP 503). |
| error:too-many-daily-captures | URL captured 10 times today; no more captures allowed. | error:too-many-redirects | Too many redirects (SPN2 follows up to 3). |
| error:too-many-requests | Host rate-limited (HTTP 429). Captures to same host may be delayed 10–20s afterwards. | error:user-session-limit | User hit concurrent capture session limit. |
| error:unauthorized | Unauthorized (HTTP 401). | error:max-daily-bandwidth | Authenticated user bandwidth limit: 5GB/day. |
| error:max-daily-bandwidth-from-ip | Anonymous bandwidth limit: 2GB/day. | error:max-daily-bandwidth-host | Host bandwidth limit: 100GB/day. |

If you used `capture_outlinks=1`, the outlinks include a `job_id` for each outlink; otherwise `outlinks` contains a list of URLs.

You can access a created capture using:

- `https://web.archive.org/web/<timestamp>/<original_url>`

## Advanced status request usage

Status of multiple captures using comma-separated `job_ids`:

```bash
curl -X POST -H "Accept: application/json" \
	-d 'job_ids=ac58789b-f3ca-48d0-9ea6-1d1225e98695,ac58789b-f3ca-48d0-9ea6-xxxxxx,ac58789b-f3ca-48d0-9ea6-yyyyyyyyy' \
	--cookie "logged-in-sig=AAAAAAAAAA;logged-in-user=user1%40archive.org;" \
	https://web.archive.org/save/status
```

Status of all outlinks using `job_id_outlinks`:

```bash
curl -X POST -H "Accept: application/json" \
	-d 'job_id_outlinks=ac58789b-f3ca-48d0-9ea6-1d1225e98695' \
	--cookie "logged-in-sig=AAAAAAAAAA;logged-in-user=user1%40archive.org;" \
	https://web.archive.org/save/status
```

## User status

```bash
curl -X GET -H "Accept: application/json" -H "Authorization: LOW myaccesskey:mysecret" \
	http://web.archive.org/save/status/user
```

To avoid a stale cache response, prefer adding a random `_t` query parameter:

- `http://web.archive.org/save/status/user?_t=1602606392499`

Example response:

```json
{"available":12,"processing":3}
```

## System status

```bash
curl -X GET -H "Accept: application/json" \
	http://web.archive.org/save/status/system
```

If OK:

```json
{"status":"ok"}
```

If overloaded:

```json
{"status":"Save Page Now servers are temporarily overloaded. Your captures may be delayed."}
```

## Tips for faster captures

- If you don’t need to know whether a capture is the first in the Archive, use `skip_first_archive=1`.
- If you’re sure the target is not HTML and can be downloaded via a plain HTTP request, use `force_get=1`.
- If the target page doesn’t require JS behaviors to load content, use `js_behavior_timeout=0`.
- Don’t use `capture_outlinks=1` unless necessary; capture specific outlinks instead.

## Limitations

| Limitation | Description |
| --- | --- |
| Network connection timeout = 10s | If connection takes &gt; 10s, target is considered unresponsive and capture errors out. |
| Max captures/min | Authenticated: 12; Anonymous: 4. If exceeded, SPN2 returns an error. |
| Max web page capture time = 50s | Browsers can spend up to 50s visiting target URL + running JS behaviors; after that the browser is terminated. |
| Max capture duration = 2m | Total time spent capturing any URL cannot exceed 2 minutes. |
| Max JS behavior runtime = 7s (configurable) | Total time running JS events cannot exceed default 5s; configurable via `js_behavior_timeout=&lt;N&gt;`. |
| Max redirects = 3 | SPN2 follows up to 3 redirects automatically. |
| Max resource size = 2GB | Max file size SPN2 can download. |
| Max outlinks captured (capture_outlinks) = 100 | First N outlinks are captured; ordering: (1) PDF, (2) ePub, (3) URLs containing “new” or “update”, (4) same domain as original. |
| Max outlinks returned = 1000 | If not capturing outlinks, SPN2 returns outlinks list only, limited to 1000 items. |
| Max embeds returned = 1000 | `resources` list is limited to 1000 items. |
| Max email links processed ([spn@archive.org](mailto:spn@archive.org)) = 500 | SPN2 tries to capture the first 500 links in emails sent to `spn@archive.org`. |
| Max captures/day | Anonymous: 4k; Authenticated: 100k (contact `info@archive.org` to increase). |
| Max captures/day per URL = 10 | Same URL can be captured at most 10 times/day. |
| Blocked URLs | Mozilla tracker-based block list may cause `error:blocked-url`. |
| Artificial delays on same host | If &gt; 20 concurrent captures on the same host, delay is concurrent_capture_number/5 seconds (e.g., 50 → 10s). |
| Max emails processed/day per user ([spn@archive.org](mailto:spn@archive.org)) = 10 | Additional emails are discarded after the limit. |
| Max screenshot size = 4MB | Larger screenshots are skipped. |
| Max data captured/day (bandwidth) | Anonymous: 2GB/day; Authenticated: 5GB/day. |

## Example PHP script (SPN2 capture)

```php
<?php
/**
* Example PHP script which captures a URL via the SPN2 API.
* Note that this script doesn't include proper exception handling and is not
* optimised for production use.
* Tested with PHP 7.0 and the PHP curl extension on Ubuntu 16.04.
*
* Full SPN2 API reference:
* https://docs.google.com/document/d/1Nsv52MvSjbLb2PCpHlat0gkzw0EvtSgpKHu4mk0MnrA/edit
*
* Archive.org credentials are required to use the SPN2 API,
* get your credentials from https://archive.org/account/s3.php
*/
$KEY = "XXX";
$SECRET = "YYY";
$TARGET_URL = "https://bbc.co.uk";
$headers = array(
	"Accept: application/json",
	"Content-Type: application/x-www-form-urlencoded;charset=UTF-8",
	"Authorization: LOW {$KEY}:{$SECRET}"
);
$params = array('url' => $TARGET_URL);

$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, "https://web.archive.org/save");
curl_setopt($ch, CURLOPT_POST, 1);
curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($params));
curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);

$response = curl_exec($ch);
curl_close($ch);

$data = json_decode($response, true);
$job_id = $data['job_id'];
print("Capture started, job id: {$job_id}\n");

while (true) {
	sleep(5);
	$response = file_get_contents("http://web.archive.org/save/status/{$job_id}");
	$data = json_decode($response, true);

	if ($data['status'] == 'success') {
		print("Capture complete: https://web.archive.org/web/{$data['timestamp']}/{$data['original_url']}\n");
		break;
	} else if ($data['status'] == 'error') {
		print("Error: {$data['message']}\n");
		break;
	}

	print("Wait, still capturing...\n");
}
?>
```

## Frequently Asked Questions

### Q1. I can see a page in my browser but SPN2 says “Live page is not available”

Before SPN2 captures a URL, it tries an HTTP `HEAD` (and if that fails, an HTTP `GET`) to verify the target is online. If those requests fail, SPN2 returns “Live page is not available”.

Common causes:

1. The site blocks Internet Archive IPs.
2. Too many concurrent captures to the same site (e.g. via `capture_outlinks`) cause firewalls to block SPN2. SPN2 mitigates by delaying captures when there are 50+ concurrent captures.
3. The site is temporarily down.

### Q2. Using `capture_outlinks` but no outlinks are captured

SPN2 extracts outlinks from HTML, PDF, RSS, XML, and JSON. For HTML it runs a JS extractor for 30 seconds that collects URLs from: `a[href]`, `area[href]`, `a[onclick]`, `a[ondblclick]`.

Extractor script:

- [https://github.com/internetarchive/brozzler/blob/master/brozzler/js-templates/extract-outlinks.js](https://github.com/internetarchive/brozzler/blob/master/brozzler/js-templates/extract-outlinks.js)

Potential issues:

1. Outlink extraction exceeded 30 seconds and was terminated.
2. Total URL capture took too long (limit 90s) and there wasn’t time for outlink extraction.
3. The target URL has no links or they’re encoded in an unsupported way.

### Q3. “Your capture will begin in XXs.”

This is commonly due to artificial delay when there are more than 20 concurrent captures to the same host.

Delay algorithm:

- when `concurrent_capture_number > 20` for the same host: delay is `concurrent_capture_number/5` seconds

Also: if a target returns HTTP `429`, subsequent captures are delayed for 10–20 seconds for the next 60 seconds.