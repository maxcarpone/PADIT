from __future__ import print_function

import rpyc
from rpyc.core import netref


class FakeConnection(object):
    def __init__(self, allowed):
        self._config = {'allow_pickle': allowed}


class FakeProxy(object):
    def __init__(self, allowed):
        self.____conn__ = FakeConnection(allowed)


class FakePickle(object):
    def __init__(self, calls):
        self.calls = calls

    def loads(self, payload):
        self.calls.append(('loads', payload))
        return 'decoded-test-value'


def run_case(allowed):
    calls = []

    original_syncreq = netref.syncreq
    original_pickle = netref.pickle

    def fake_syncreq(proxy, handler, protocol):
        calls.append(('syncreq', handler, protocol))
        return 'harmless-test-payload'

    netref.syncreq = fake_syncreq
    netref.pickle = FakePickle(calls)

    try:
        method = netref._make_method('__array__', 'test')

        try:
            result = method(FakeProxy(allowed))
            return ('returned', result, calls)
        except ValueError as exc:
            return ('blocked', str(exc), calls)

    finally:
        netref.syncreq = original_syncreq
        netref.pickle = original_pickle


def main():
    print('=== RPYC SECURITY TEST ===')
    print('RPyC version:', rpyc.__version__)
    print('Netref module:', netref.__file__)

    assert tuple(rpyc.__version__) == (4, 1, 5)

    denied = run_case(False)
    allowed = run_case(True)

    print('allow_pickle=False:', denied)
    print('allow_pickle=True:', allowed)

    assert denied[0] == 'blocked'
    assert denied[1] == 'pickling is disabled'
    assert denied[2] == []

    print('[PASS] Disabled pickling rejected before remote request')

    assert allowed[0] == 'returned'
    assert allowed[1] == 'decoded-test-value'

    assert allowed[2] == [
        ('syncreq', netref.consts.HANDLE_PICKLE, -1),
        ('loads', 'harmless-test-payload')
    ]

    print('[PASS] Explicitly enabled pickling behavior preserved')
    print('=== RPYC SECURITY: 2/2 PASS ===')


if __name__ == '__main__':
    main()
