# Adding Ruru status to your app

> **Deferred:** this is a proposed integration, not a Release feature. Ruru
> exposes it only behind a developer toggle in Debug builds while the work is
> parked on the [roadmap](ROADMAP.md#2026-10-20--enhanced-monitoring-deferred).

The proposal lets an app with an HTTP(S) server or Web UI give Ruru a richer
view of itself by serving one small JSON document.

This is monitoring only. Serving the document gives your app no lease, token or
special access to Ruru, and Ruru never treats it as proof of identity.

- Format: [`ruru-status-v1.schema.json`](ruru-status-v1.schema.json) (JSON Schema)
- Design and Ruru-side behaviour: [Enhanced monitoring](ENHANCED_MONITORING.md)

## 1. Serve the document

Answer `GET /.well-known/ruru` on the same scheme, host and port that operators
monitor. Send HTTP `200`, `Content-Type: application/json` and
`Cache-Control: no-store`. Don't redirect: Ruru never follows redirects.

```json
{
  "ruru": 1,
  "app": { "id": "com.example.app", "name": "Example", "version": "2.3.0", "build": "412" },
  "state": "degraded",
  "reasonCode": "queue_backlog",
  "uptimeSeconds": 86400,
  "components": [
    { "id": "database", "name": "Database", "state": "ready" },
    { "id": "worker", "name": "Background worker", "state": "degraded", "reasonCode": "queue_backlog" }
  ],
  "metrics": [
    { "id": "queued", "name": "Queued jobs", "value": 42, "unit": "count" },
    { "id": "latency", "name": "Job latency", "value": 180, "unit": "ms" }
  ],
  "links": [
    { "rel": "dashboard", "title": "Dashboard", "url": "https://app.example.com/admin" }
  ]
}
```

Only `ruru`, `app.id`, `app.name` and `state` are required.

| Field | Rules |
| --- | --- |
| `state`, component `state` | `ready`, `synchronizing`, `outdated`, `degraded` or `unknown` |
| `id`, `reasonCode` | Lower-case ASCII `[a-z0-9._-]`, 1–48 characters |
| `name`, `title` | Display text, 1–64 characters |
| `version`, `build` | 1–32 characters |
| `unit` | 1–16 characters; `count` is shown without a unit |
| Lists | At most 16 components, 16 metrics and 4 links; ids unique |
| Size | 16 KiB maximum |

Ruru ignores fields it doesn't know, so you can add your own. A document that
breaks a rule is shown as "Status document is invalid" and the rest of the
check still works. `degraded` and `outdated` appear as warnings. Ruru never
counts a reachable app as down because of what the document says.

## 2. Decide who can read it

The document is unauthenticated, like a `/health` route. Treat it as public
unless you restrict it, and offer operators a setting with three choices:

| Setting | Behaviour |
| --- | --- |
| Off (default) | Answer `404`, as if the route did not exist |
| Local network | Serve only direct requests from loopback or private addresses. Refuse anything that arrived through a proxy or tunnel. A Cloudflare tunnel connects from `127.0.0.1` but adds `CF-Connecting-IP`, so check forwarding headers as well as the peer address. |
| Everywhere | Serve anyone who can reach the server, including through a public domain |

Never include secrets, tokens, user or account names, email addresses,
internal hostnames or IP addresses, file paths, log lines or error messages.
Use counts and machine `reasonCode`s. Even then, a public document reveals your
app's name, version and uptime, which can help someone target a known bug in an
old version. Leave out `build` and `uptimeSeconds` if that matters to you.

## 3. Examples

### Swift (RuruClient)

`RuruStatusDocument` enforces the same limits as Ruru, and `response(...)`
applies the exposure setting:

```swift
import RuruClient

let document = RuruStatusDocument(
    app: .init(id: "com.example.app", name: "Example", version: appVersion),
    state: workerHealthy ? .ready : .degraded,
    components: [.init(id: "worker", name: "Background worker", state: workerHealthy ? .ready : .degraded)],
    metrics: [.init(id: "queued", name: "Queued jobs", value: Double(queue.count), unit: "count")])

let reply = document.response(exposure: settings.ruruStatusExposure,     // .off by default
                              requestHeaders: request.headers,
                              remoteAddress: connection.remoteIP)
// Send reply.status, reply.headers and reply.body with your server.
```

### Node.js (Express)

```js
const FORWARDED = ['forwarded', 'x-forwarded-for', 'x-real-ip', 'cf-connecting-ip', 'cf-ray', 'true-client-ip'];
const isPrivate = (ip) => /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1$|f[cd]|fe80:)/i.test(ip.replace(/^::ffff:/, ''));

app.get('/.well-known/ruru', (req, res) => {
  const exposure = settings.ruruStatusExposure; // 'off' | 'localNetwork' | 'everywhere'
  const local = !FORWARDED.some((h) => h in req.headers) && isPrivate(req.socket.remoteAddress || '');
  if (exposure === 'off' || (exposure === 'localNetwork' && !local)) return res.sendStatus(404);
  res.set('Cache-Control', 'no-store').json({
    ruru: 1,
    app: { id: 'com.example.app', name: 'Example', version: pkg.version },
    state: queue.healthy ? 'ready' : 'degraded',
    metrics: [{ id: 'queued', name: 'Queued jobs', value: queue.length, unit: 'count' }],
  });
});
```

### Python (Flask)

```python
import ipaddress
FORWARDED = {"forwarded", "x-forwarded-for", "x-real-ip", "cf-connecting-ip", "cf-ray", "true-client-ip"}

@app.get("/.well-known/ruru")
def ruru_status():
    exposure = settings.ruru_status_exposure  # "off" | "localNetwork" | "everywhere"
    proxied = any(h.lower() in FORWARDED for h in request.headers.keys())
    local = not proxied and ipaddress.ip_address(request.remote_addr).is_private
    if exposure == "off" or (exposure == "localNetwork" and not local):
        abort(404)
    response = jsonify(ruru=1, app={"id": "com.example.app", "name": "Example", "version": VERSION},
                       state="ready" if worker.healthy else "degraded")
    response.headers["Cache-Control"] = "no-store"
    return response
```

### Static file

An app without a server-side language can publish a fixed file at
`/.well-known/ruru` containing only `ruru`, `app` and `"state": "unknown"`.
Ruru then shows the app's name and version, and checks reachability as usual.

## 4. Test it

```bash
curl -i http://localhost:8080/.well-known/ruru
```

Check that the answer is `200` with `application/json`, and that it validates
against the schema. Testing it with Ruru currently requires a Debug build and
the **Settings → General → Developer → Enhanced monitoring** toggle.
