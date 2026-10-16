from werkzeug.http import parse_cookie

header = '==__Host-eq=bad;__Host-eq=good;'
cookies = parse_cookie(header)

if cookies.get('__Host-eq') != 'good':
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie took precedence"
    )

if cookies.getlist('__Host-eq') != ['good']:
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie was not discarded"
    )

print("CVE-2023-23934 COOKIE PARSING TEST: PASS")