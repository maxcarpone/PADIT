import jinja2
from jinja2 import Environment

expected = "2.11.3"

if jinja2.__version__ != expected:
    raise SystemExit(
        "Unexpected Jinja2 version: %s (expected %s)"
        % (jinja2.__version__, expected)
    )

env = Environment()

good = env.from_string("{{ attrs|xmlattr }}").render(
    attrs={u"class": u"ok", u"data-id": u"42"}
)

if 'class="ok"' not in good or 'data-id="42"' not in good:
    raise AssertionError("Valid xmlattr regression: %r" % (good,))

for sep in (u"\t", u"\n", u"\f", u" ", u"/", u">", u"="):
    key = u"class%sonclick" % sep

    try:
        env.from_string("{{ attrs|xmlattr }}").render(
            attrs={key: u"alert(1)"}
        )
    except ValueError:
        pass
    else:
        raise AssertionError(
            "Invalid xmlattr key unexpectedly accepted: %r" % (key,)
        )

from jinja2.sandbox import SandboxedEnvironment
from jinja2.exceptions import SecurityError

sandbox_env = SandboxedEnvironment()

def call_filter(value, arg):
    return value(arg)

sandbox_env.filters["call"] = call_filter

indirect_format = sandbox_env.from_string(
    "{{ '{0.__class__}'.format | call(42) }}"
)

try:
    result = indirect_format.render()
except SecurityError:
    pass
else:
    if "__class__" in result or "int" in result:
        raise AssertionError(
            "Indirect str.format escaped sandbox: %r" % result
        )

attr_format = sandbox_env.from_string(
    "{{ ('{0.__class__}'|attr('format'))(42) }}"
)

try:
    result = attr_format.render()
except SecurityError:
    pass
else:
    if "__class__" in result or "int" in result:
        raise AssertionError(
            "attr('format') escaped sandbox: %r" % result
        )

class AttrCompatObject(object):
    value = "attribute-ok"

if env.from_string(
    "{{ obj|attr('value') }}"
).render(obj=AttrCompatObject()) != "attribute-ok":
    raise AssertionError("attr filter attribute lookup regression")

item_only = env.from_string(
    "{{ obj|attr('value') }}"
).render(obj={"value": "item-must-not-be-used"})

if item_only != "":
    raise AssertionError(
        "attr filter unexpectedly fell back to item lookup: %r"
        % item_only
    )

print(">>> Jinja2 version verified: %s" % jinja2.__version__)
print("CVE-2024-22195 REGRESSION TEST: PASS")
print("CVE-2024-34064 REGRESSION TEST: PASS")
print("CVE-2024-56326 REGRESSION TEST: PASS")
print("CVE-2025-27516 REGRESSION TEST: PASS")
print("JINJA2 ATTR COMPATIBILITY TEST: PASS")