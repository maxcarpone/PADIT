#!/usr/bin/env python2
# -*- coding: utf-8 -*-
from __future__ import print_function

import sys

import passlib
import netifaces
import flask_login

from passlib.hash import pbkdf2_sha256
from flask import Flask
from flask_login import (
    LoginManager, UserMixin, login_user,
    current_user, logout_user
)

print("=== PADIT SERVER DEPENDENCIES M02 ===")

assert sys.version_info[:2] == (2, 7)
assert passlib.__version__ == "1.7.4"
assert flask_login.__version__ == "0.5.0"

# Validate native netifaces distribution.
import pkg_resources
assert pkg_resources.get_distribution("netifaces").version == "0.11.0"

password = "PADIT-M02-test-password"
hashed = pbkdf2_sha256.hash(password, rounds=1000)

assert pbkdf2_sha256.verify(password, hashed)
assert not pbkdf2_sha256.verify("incorrect", hashed)
print("PASSLIB: PASS")

interfaces = netifaces.interfaces()
assert isinstance(interfaces, list)
assert interfaces

for interface in interfaces:
    assert isinstance(netifaces.ifaddresses(interface), dict)

print("NETIFACES: PASS")

app = Flask("padit-m02-test")
app.config["SECRET_KEY"] = "temporary-test-key"

manager = LoginManager()
manager.init_app(app)

class TestUser(UserMixin):
    id = "padit-user"

@manager.user_loader
def load_user(user_id):
    return TestUser() if user_id == "padit-user" else None

with app.test_request_context("/"):
    assert not current_user.is_authenticated
    assert login_user(TestUser())
    assert current_user.is_authenticated
    assert current_user.get_id() == "padit-user"
    logout_user()
    assert not current_user.is_authenticated

print("FLASK-LOGIN: PASS")

for name in (
    "requests", "urllib3", "eventlet", "ldap3",
    "flask", "flask_socketio", "socketio",
    "engineio", "OpenSSL", "cryptography",
    "peewee", "babel", "wtforms", "lxml",
    "waptutils", "waptcrypto"
):
    __import__(name)
    print("%-20s PASS" % name)

print("PADIT SERVER DEPENDENCIES M02: PASS")
