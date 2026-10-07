"""Minimal Ruru lease loop using only the Python standard library.

Usage:
    RURU_ENDPOINT=https://ruru.example.com RURU_CLUSTER=media RURU_NODE=studio \
    RURU_TOKEN=... python3 ruru_lease.py

Follows the client checklist in Documentation/INTEGRATIONS.md: deadlines are
measured from when each request is sent on a monotonic clock, renewals happen at
a third of the lease, 409 on renew is immediate loss, and the term is the
fencing token to attach to every side effect.
"""
import json
import os
import random
import time
import urllib.error
import urllib.request

ENDPOINT = os.environ["RURU_ENDPOINT"].rstrip("/")
CLUSTER = os.environ["RURU_CLUSTER"]
NODE = os.environ["RURU_NODE"]
TOKEN = os.environ["RURU_TOKEN"]  # keep secret; never log it


class Held(Exception): pass
class Lost(Exception): pass
class Unavailable(Exception): pass


def call(action, term):
    body = json.dumps({"clusterID": CLUSTER, "nodeID": NODE, "term": term, "nodeName": NODE}).encode()
    request = urllib.request.Request(f"{ENDPOINT}/v1/lease/{action}", data=body, method="POST",
                                     headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    sent = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return sent, json.load(response)
    except urllib.error.HTTPError as error:
        code = json.loads(error.read() or b"{}").get("error", "")
        if error.code == 409:
            raise Held() if code == "ownership_held" else Lost()
        raise Unavailable(f"{error.code} {code}")
    except OSError as error:
        raise Unavailable(str(error))


def start_work(term, deadline): print(f"owner, term {term}; fence every side effect with it")
def stop_work(): print("not owner; stop guarded work")


def main():
    term, deadline, owner = 0, 0.0, False
    while True:
        try:
            sent, grant = call("renew" if owner else "acquire", term)
            if grant["ownerNodeID"] != NODE:
                raise Held()
            term, duration = grant["term"], grant["expiresInSeconds"]
            deadline = sent + duration
            if not owner:
                owner = True
                start_work(term, deadline)
            time.sleep(duration / 3)
        except (Held, Lost):
            if owner:
                owner = False
                stop_work()
            time.sleep(random.uniform(4, 6))
        except Unavailable:
            if owner and time.monotonic() >= deadline:
                owner = False
                stop_work()
            time.sleep(1 if owner else random.uniform(4, 6))


if __name__ == "__main__":
    main()
