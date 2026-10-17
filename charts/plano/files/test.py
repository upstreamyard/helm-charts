# helm test: Envoy answers /healthz, brightstaff lists the configured models, and
# (optional) a chat completion goes through to the default model provider.
import json, os, time, urllib.request

url = os.environ["PLANO_URL"]

def call(path, body=None):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode() if body else None,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.status, json.loads(resp.read() or b"null") if path != "/healthz" else None

for attempt in range(10):
    try:
        call("/healthz")
        break
    except OSError as e:
        print("waiting for Plano:", e)
        time.sleep(3)
else:
    raise SystemExit("Plano did not answer /healthz")

status, models = call("/v1/models")
print("models:", [m["id"] for m in models["data"]])
assert models["data"], "no models configured"

if os.environ.get("TEST_MODEL"):
    status, reply = call("/v1/chat/completions", {
        "model": os.environ["TEST_MODEL"],
        "messages": [{"role": "user", "content": "Reply with one word: ok"}],
    })
    print("chat completion:", reply["choices"][0]["message"]["content"])
print("ok")
