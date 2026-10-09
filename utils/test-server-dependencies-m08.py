# -*- coding: utf-8 -*-
"""PADIT M08 - ldap3 2.9.1 compatibility regression tests."""

from __future__ import print_function

import ldap3
from ldap3 import Server, Connection, MOCK_SYNC, SUBTREE
from ldap3.utils.dn import parse_dn


def test_dn_parsing():
    samples = [
        'CN=Jean Dupont,OU=Utilisateurs,DC=exemple,DC=fr',
        r'CN=Doe\, John,OU=Users,DC=example,DC=org',
        'CN=Ordinateur-01,OU=Postes,DC=exemple,DC=fr',
    ]

    for dn in samples:
        parsed = parse_dn(dn)
        assert parsed, dn

    escaped = parse_dn(samples[1])
    assert escaped[0] == ('CN', r'Doe\, John', ','), escaped

    print('LDAP DN parsing: PASS')


def test_mock_directory():
    server = Server('padit-test.local', get_info=ldap3.NONE)

    conn = Connection(
        server,
        user='CN=Administrateur,DC=padit,DC=local',
        password='test-only',
        client_strategy=MOCK_SYNC
    )

    conn.strategy.add_entry(
        'CN=Administrateur,DC=padit,DC=local',
        {
            'objectClass': ['top', 'person'],
            'cn': ['Administrateur'],
            'sn': ['Administrateur'],
            'userPassword': ['test-only'],
        }
    )

    conn.strategy.add_entry(
        'CN=Jean Dupont,OU=Utilisateurs,DC=padit,DC=local',
        {
            'objectClass': ['top', 'person', 'user'],
            'cn': [u'Jean Dupont'],
            'sn': [u'Dupont'],
            'displayName': [u'Jean Dupont'],
            'sAMAccountName': ['jdupont'],
        }
    )

    conn.strategy.add_entry(
        'CN=PC-001,OU=Postes,DC=padit,DC=local',
        {
            'objectClass': ['top', 'computer'],
            'cn': ['PC-001'],
            'sAMAccountName': ['PC-001$'],
        }
    )

    try:
        assert conn.bind(), conn.result
        print('LDAP mock bind: PASS')

        assert conn.search(
            'DC=padit,DC=local',
            '(sAMAccountName=jdupont)',
            search_scope=SUBTREE,
            attributes=['cn', 'displayName', 'sAMAccountName']
        ), conn.result

        assert len(conn.entries) == 1, conn.entries
        assert str(conn.entries[0].sAMAccountName) == 'jdupont'
        print('LDAP user lookup: PASS')

        assert conn.search(
            'DC=padit,DC=local',
            '(sAMAccountName=PC-001$)',
            search_scope=SUBTREE,
            attributes=['cn', 'sAMAccountName']
        ), conn.result

        assert len(conn.entries) == 1, conn.entries
        print('LDAP computer lookup: PASS')
    finally:
        conn.unbind()


def main():
    assert ldap3.__version__ == '2.9.1', ldap3.__version__

    test_dn_parsing()
    test_mock_directory()

    print('PADIT SERVER DEPENDENCIES M08: PASS')


if __name__ == '__main__':
    main()
