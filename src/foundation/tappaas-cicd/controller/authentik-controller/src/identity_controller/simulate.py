"""TAPPAAS_SIMULATE=1 for a controller's API calls (docs/plans/console-gui-pipeline.md
§6 layer B): the one place the writes pass, httpx's send. A read goes out; a write is
logged on stderr and answered as saved, so a plan runs to its end. The same file
stands in opnsense_controller and identity_controller, which are built apart;
scripts/test/test-simulate-coverage.sh keeps them equal.
"""

import os
import re
import sys

# POST is how OPNsense lists: searchItem, search_item, get, status.
_READ_POST = re.compile(r"/(search|get|list|dump|status|export|find|info)[^/]*$", re.IGNORECASE)


def simulating() -> bool:
    return os.environ.get("TAPPAAS_SIMULATE") == "1"


def is_read(method: str, path: str) -> bool:
    return method in ("GET", "HEAD", "OPTIONS") or (method == "POST" and bool(_READ_POST.search(path)))


def install() -> None:
    if not simulating():
        return
    import httpx

    real = httpx.Client.send

    def send(self, request, **kwargs):
        if is_read(request.method, request.url.path):
            return real(self, request, **kwargs)
        print(f"[simulate] {request.method} {request.url}", file=sys.stderr)
        return httpx.Response(200, json={"result": "saved", "status": "ok"}, request=request)

    httpx.Client.send = send
