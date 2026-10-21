# -*- coding: utf-8 -*-
"""PADIT soupsieve 1.9.6 security regression tests (Python 2.7)."""

import time

import soupsieve


def compile_within(selector, max_seconds=0.5):
    start = time.time()
    try:
        soupsieve.compile(selector)
        accepted = True
    except soupsieve.SelectorSyntaxError:
        accepted = False

    elapsed = time.time() - start
    assert elapsed < max_seconds, (
        "Selector compilation took %.3fs" % elapsed
    )
    return accepted


def test_cve_2026_49476_selector_limit():
    assert compile_within(",".join(["a"] * 1024))
    assert not compile_within(",".join(["a"] * 1025))


def test_cve_2026_49476_relative_limit():
    assert compile_within(
        "div:has(" + ",".join(["a"] * 1024) + ")"
    )
    assert not compile_within(
        "div:has(" + ",".join(["a"] * 1025) + ")"
    )


def test_cve_2026_49476_token_budget():
    assert not compile_within("a > " * 2100 + "b")


def test_cve_2026_49477_unterminated_quotes():
    assert not compile_within('[a="' + "x" * 24)
    assert not compile_within("[a='" + "x" * 24)
    assert compile_within('[a="bonjour monde"]')


def test_cve_2026_85999_whitespace():
    assert compile_within("a" + " " * 2000 + "b")


def test_cve_2026_86000_identifier():
    assert not compile_within("[a=" + "a" * 30)
    assert compile_within("[a=bonjour]")
