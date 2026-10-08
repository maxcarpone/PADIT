# -*- coding: utf-8 -*-
"""PADIT M04 - Flask-Babel 1.0.0 compatibility regression tests."""

from __future__ import print_function

import os
from datetime import datetime

import pkg_resources
from flask import Flask, session
from flask_babel import Babel, gettext, get_locale, format_date


def main():
    version = pkg_resources.get_distribution("Flask-Babel").version
    assert version == "1.0.0", "Unexpected Flask-Babel version: %s" % version

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    translations = os.path.join(repo_root, "waptserver", "translations")

    assert os.path.isfile(os.path.join(
        translations, "fr", "LC_MESSAGES", "messages.mo"
    ))

    app = Flask("padit-m04-regression")
    app.secret_key = "padit-m04-test-only"
    app.config["BABEL_DEFAULT_LOCALE"] = "fr"
    app.config["BABEL_DEFAULT_TIMEZONE"] = "Europe/Paris"
    app.config["BABEL_TRANSLATION_DIRECTORIES"] = translations

    babel = Babel(app)

    @babel.localeselector
    def select_locale():
        return session.get("lang", "fr")

    message = "You have to login with proper credentials"
    expected_fr = u"Vous devez vous connecter avec les bons identifiants"

    with app.test_request_context("/"):
        session["lang"] = "fr"

        assert str(get_locale()) == "fr"
        assert gettext(message) == expected_fr

        formatted = format_date(datetime(2026, 10, 8), format="short")
        assert formatted == "08/10/2026", formatted

    with app.test_request_context("/"):
        session["lang"] = "de"

        assert str(get_locale()) == "de"
        assert gettext(message) == message

    print("PADIT SERVER DEPENDENCIES M04: PASS")


if __name__ == "__main__":
    main()
