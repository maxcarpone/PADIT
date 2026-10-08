# -*- coding: utf-8 -*-
"""PADIT M05 - Click and WTForms compatibility regression tests."""

from __future__ import print_function

import click
import wtforms

from click.testing import CliRunner
from flask import Flask
from wtforms import Form, StringField, validators


@click.command()
@click.option("--name", default="PADIT")
def hello(name):
    click.echo("Hello " + name)


class TestForm(Form):
    name = StringField("Name", [
        validators.DataRequired(),
        validators.Length(min=3)
    ])


def main():
    assert click.__version__ == "7.1.2"
    assert wtforms.__version__ == "2.3.3"

    # Click standalone CLI
    result = CliRunner().invoke(hello, ["--name", "M05"])
    assert result.exit_code == 0, (result.output, result.exception)
    assert result.output.strip() == "Hello M05"
    print("Click CLI: PASS")

    # Flask 1.1.4 / Click 7.1.2 integration
    app = Flask("padit-m05-test")

    @app.cli.command("padit-check")
    def padit_check():
        click.echo("PADIT Flask CLI OK")

    result = app.test_cli_runner().invoke(args=["padit-check"])
    assert result.exit_code == 0, (result.output, result.exception)
    assert result.output.strip() == "PADIT Flask CLI OK"
    print("Flask CLI: PASS")

    # WTForms field validation
    valid = TestForm(name="PADIT")
    invalid = TestForm(name="X")

    assert valid.validate(), valid.errors
    assert not invalid.validate()
    assert "name" in invalid.errors
    print("WTForms validation: PASS")

    print("PADIT SERVER DEPENDENCIES M05: PASS")


if __name__ == "__main__":
    main()
