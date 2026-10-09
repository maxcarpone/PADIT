# -*- coding: utf-8 -*-
"""PADIT M09 - MarkupSafe 1.1.1 compatibility regression tests."""

from __future__ import print_function

import pkg_resources
import markupsafe
import markupsafe._speedups as speedups

from markupsafe import Markup, escape
from jinja2 import Environment


def main():
    version = pkg_resources.get_distribution("MarkupSafe").version
    assert version == "1.1.1", version

    assert speedups.__file__.endswith(".so"), speedups.__file__

    class HTMLFailure(object):
        def __html__(self):
            raise ValueError("PADIT M09 expected error")

    try:
        escape(HTMLFailure())
    except ValueError:
        pass
    else:
        raise AssertionError("Expected ValueError")

    assert str(escape("<script>")) == "&lt;script&gt;"

    env = Environment(autoescape=True)
    template = env.from_string("{{ value }}")

    assert template.render(value="<script>") == "&lt;script&gt;"
    assert template.render(
        value=Markup("<strong>OK</strong>")
    ) == "<strong>OK</strong>"

    print("MarkupSafe C extension: PASS")
    print("Jinja2 integration: PASS")
    print("PADIT SERVER DEPENDENCIES M09: PASS")


if __name__ == "__main__":
    main()
