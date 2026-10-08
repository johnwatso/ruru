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
import math
import os
import random
import threading
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


# Replace these with an idempotent start/deadline update and synchronous stop/drain.
def start_work(term, deadline): print(f"owner, term {term}; fence every side effect with it")
def stop_work(): print("not owner; stop guarded work")


class WorkGate:
    """Expire work independently of blocking HTTP calls.

    Real workers must also check the monotonic deadline before every effect,
    fence it with the term, and make stop_work synchronously stop/drain output.
    A Python thread cannot protect against suspension of the entire process.
    """
    def __init__(self):
        self.condition = threading.Condition()
        self.deadline = 0.0
        self.owner = False
        self.closed = False
        self.watcher = threading.Thread(target=self.watch, daemon=True)
        self.watcher.start()

    def grant(self, term, deadline):
        with self.condition:
            if time.monotonic() >= deadline:
                raise Lost()
            self.deadline, self.owner = deadline, True
            # Update the worker's deadline on renewals too.
            start_work(term, deadline)
            self.condition.notify_all()

    def stop(self):
        with self.condition:
            if self.owner:
                self.owner = False
                stop_work()
            self.deadline = 0.0
            self.condition.notify_all()

    def watch(self):
        with self.condition:
            while not self.closed:
                if not self.owner:
                    self.condition.wait()
                elif time.monotonic() >= self.deadline:
                    self.stop()
                else:
                    self.condition.wait(self.deadline - time.monotonic())

    def close(self):
        with self.condition:
            self.stop()
            self.closed = True
            self.condition.notify_all()
        self.watcher.join()


def main():
    term, deadline, owner = 0, 0.0, False
    work = WorkGate()
    try:
        while True:
            try:
                if owner and time.monotonic() >= deadline:
                    owner = False
                    work.stop()
                sent, grant = call("renew" if owner else "acquire", term)
                duration, granted_term = grant.get("expiresInSeconds"), grant.get("term")
                if (type(duration) not in (int, float) or not math.isfinite(duration) or not 0 < duration <= 300
                        or type(granted_term) is not int or not 0 < granted_term < (1 << 62)):
                    raise Unavailable("invalid grant")
                if grant.get("ownerNodeID") != NODE or granted_term < term:
                    raise Held()
                if owner and granted_term != term:
                    raise Lost()
                deadline = sent + duration - min(2, duration / 10)
                work.grant(granted_term, deadline)
                term, owner = granted_term, True
                time.sleep(min(duration / 3, max(0, deadline - time.monotonic())))
            except (Held, Lost):
                owner = False
                work.stop()
                time.sleep(random.uniform(4, 6))
            except Unavailable:
                if owner and time.monotonic() >= deadline:
                    owner = False
                    work.stop()
                time.sleep(min(1, max(0, deadline - time.monotonic())) if owner else random.uniform(4, 6))
    finally:
        work.close()


if __name__ == "__main__":
    main()
