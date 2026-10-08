#!/usr/bin/env python2
# -*- coding: utf-8 -*-

from __future__ import print_function

import os
import sys
from StringIO import StringIO

import six
import pyparsing
import iniparse


def require(condition, message):
    if not condition:
        raise AssertionError(message)


print("=== PADIT SERVER DEPENDENCIES M01 ===")

require(sys.version_info[:2] == (2, 7),
        "Python 2.7 required")

require(six.__version__ == "1.17.0",
        "Unexpected six version: %s" % six.__version__)

require(pyparsing.__version__ == "2.4.7",
        "Unexpected pyparsing version: %s" % pyparsing.__version__)

require(six.PY2, "six.PY2 must be true")
require(six.ensure_text(b"PADIT") == u"PADIT",
        "six Unicode conversion failed")
require(six.ensure_binary(u"PADIT") == b"PADIT",
        "six bytes conversion failed")

expression = (
    pyparsing.Word(pyparsing.alphas)
    + pyparsing.Suppress("=")
    + pyparsing.Word(pyparsing.alphanums)
)

require(
    expression.parseString("version=183").asList()
    == ["version", "183"],
    "pyparsing failed"
)

try:
    expression.parseString("=invalid")
except pyparsing.ParseException:
    pass
else:
    raise AssertionError("Invalid parsing accepted")

source = StringIO(
    "# PADIT configuration\n"
    "[server]\n"
    "port = 8080\n"
    "enabled = true\n"
    "\n"
    "[database]\n"
    "host = localhost\n"
)

config = iniparse.INIConfig(source)

require(config.server.port == "8080", "INI read failed")
require(config.server.enabled == "true", "INI boolean read failed")
require(config.database.host == "localhost", "INI section read failed")

config.server.port = "8081"
output = str(config)

require("port = 8081" in output, "INI write failed")
require("# PADIT configuration" in output,
        "INI comment preservation failed")
require("[database]" in output,
        "INI section preservation failed")

for name in (
    "requests", "urllib3", "eventlet", "ldap3",
    "flask", "flask_login", "flask_socketio",
    "socketio", "engineio", "OpenSSL",
    "cryptography", "peewee", "babel",
    "wtforms", "passlib", "lxml",
    "waptutils", "waptcrypto"
):
    __import__(name)
    print("%-20s PASS" % name)

print("PADIT SERVER DEPENDENCIES M01: PASS")
