from werkzeug.debug import DebuggedApplication
from werkzeug.test import Client
from werkzeug.wrappers import Response


def app(environ, start_response):
    response = Response("normal")
    return response(environ, start_response)


debug_app = DebuggedApplication(app, evalex=True)
client = Client(debug_app, Response)

bad = client.get(
    "/console",
    headers={"Host": "attacker.example"},
)

good = client.get(
    "/console",
    headers={"Host": "localhost"},
)

if bad.status_code != 400:
    raise RuntimeError(
        "CVE-2024-34069 regression: untrusted debugger Host was accepted"
    )

if good.status_code != 200:
    raise RuntimeError(
        "CVE-2024-34069 regression: trusted localhost debugger Host was rejected"
    )

print("CVE-2024-34069 DEBUGGER HOST TRUST TEST: PASS")