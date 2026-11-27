# -*- coding: utf-8 -*-
"""Confirmation through WAPT's signed update_host inventory exchange."""

import hashlib
import base64
import json
import os
import re
import time
import uuid
from urlparse import urlsplit


class ConfirmationError(RuntimeError):
    pass


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def _transition_id(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise ConfirmationError('Invalid transition identifier')


def prepare_inventory(inventory, expected_uuid, expected_version, transition_id):
    """Return the exact bytes to sign and the acknowledgement expected for this attempt."""
    if inventory.get('uuid') != expected_uuid:
        raise ConfirmationError('Local inventory UUID differs from the historical UUID')
    status = inventory.get('wapt_status')
    host = inventory.get('host_info')
    if (not isinstance(status, dict) or status.get('wapt-get-version') != expected_version or
            not re.match(r'\A1\.8\.3\.[0-9]+\Z', expected_version)):
        raise ConfirmationError('Local inventory version differs from the expected PADIT version')
    if not isinstance(host, dict) or not host.get('computer_fqdn'):
        raise ConfirmationError('Fresh host inventory is required')
    payload = dict(inventory)
    payload['transition_id'] = _transition_id(transition_id)
    status, host = dict(status), dict(host)
    nonce = uuid.uuid4().hex
    status['padit_transition_confirmation'] = nonce
    host['padit_transition_confirmation'] = nonce
    payload['wapt_status'] = status
    payload['host_info'] = host
    hashes = dict(payload.get('status_hashes', {}))
    expected_hashes = dict((key, hashlib.sha256(_canonical(payload[key])).hexdigest())
                           for key in ('wapt_status', 'host_info'))
    hashes.update(expected_hashes)
    payload['status_hashes'] = hashes
    return _canonical(payload), expected_hashes, nonce


def verify_acknowledgement(response, expected_uuid, expected_hashes, nonce, transition_id):
    """Accept only the response to the signed POST over authenticated target HTTPS."""
    if not isinstance(response, dict) or response.get('success') is not True:
        # Unknown hosts and existing hosts lacking a certificate are indistinguishable.
        raise ConfirmationError('Target rejected signed inventory or requires explicit enrollment')
    result = response.get('result')
    if not isinstance(result, dict) or result.get('uuid') != expected_uuid:
        raise ConfirmationError('Target acknowledged the wrong UUID')
    readback = result.get('transition_confirmation')
    if (not isinstance(readback, dict) or readback.get('nonce') != nonce or readback.get('uuid') != expected_uuid or
            readback.get('transition_id') != _transition_id(transition_id) or not readback.get('confirmed_at')):
        raise ConfirmationError('Missing server read-back for this confirmation attempt')
    hashes = readback.get('inventory_sha256')
    if (not isinstance(hashes, dict) or set(expected_hashes) != set(('wapt_status', 'host_info')) or
            any(hashes.get(key) != value for key, value in expected_hashes.items())):
        raise ConfirmationError('Target did not acknowledge this fresh inventory and version')


def _signed_post(target, ca_path, cert, key, endpoint, data, timeout):
    import requests

    try:
        server = urlsplit(target)
        valid_target = (server.scheme == 'https' and server.hostname and
                        not (server.username or server.password or server.query or server.fragment) and
                        not re.search(r'[\\@\s]', target))
    except ValueError:
        valid_target = False
    if not valid_target or not os.path.isfile(ca_path) or not 0 < timeout <= 30:
        raise ConfirmationError('Confirmation requires the approved HTTPS target, CA file and timeout')
    try:
        signature = key.sign_content(hashlib.sha256(data).hexdigest())
    except Exception:
        raise ConfirmationError('Cannot sign request using the existing host identity')
    # time.clock is a monotonic elapsed-time clock on the Windows Python runtime.
    clock = time.clock if os.name == 'nt' else time.time
    deadline = clock() + timeout
    session = requests.Session()
    session.trust_env = False
    response = None
    try:
        response = session.post(target.rstrip('/') + endpoint, data=data, stream=True,
            headers={'Content-Type': 'application/json', 'Accept-Encoding': 'identity',
                     'X-Signature': base64.b64encode(signature), 'X-Signer': cert.cn},
            verify=ca_path, allow_redirects=False, timeout=min(timeout, 5))
        if response.status_code != 200 or clock() >= deadline:
            raise ConfirmationError('Target did not return a timely inventory acknowledgement')
        body = bytearray()
        for byte in response.iter_content(chunk_size=1):
            body.extend(byte)
            if len(body) > 65536 or clock() >= deadline:
                raise ConfirmationError('Target response exceeded confirmation limits')
        if clock() >= deadline:
            raise ConfirmationError('Confirmation deadline exceeded')
        return json.loads(bytes(body))
    except ConfirmationError:
        raise
    except (requests.RequestException, ValueError):
        raise ConfirmationError('Target HTTPS confirmation failed')
    finally:
        if response is not None:
            response.close()
        session.close()


def _load_identity(key_path, cert_path, uuid):
    from waptcrypto import SSLPrivateKey, SSLCertificate

    try:
        key = SSLPrivateKey(filename=key_path)
        cert = SSLCertificate(crt_filename=cert_path)
        if cert.cn.lower() != uuid.lower() or not cert.match_key(key):
            raise ConfirmationError('Existing certificate does not match the historical identity')
        return cert, key
    except ConfirmationError:
        raise
    except Exception:
        raise ConfirmationError('Cannot load the existing host identity')


def enroll_transition_host(target, ca_path, key_path, cert_path, uuid, hostname, transition, timeout=15):
    cert, key = _load_identity(key_path, cert_path, uuid)
    enrollment = dict(transition, transition_id=_transition_id(transition['transition_id']),
                      issued_at=int(time.time()))
    data = _canonical(dict(uuid=uuid, host_info=dict(computer_fqdn=hostname),
                           host_certificate=cert.as_pem(), transition=enrollment))
    response = _signed_post(target, ca_path, cert, key, '/transition/enroll', data, timeout)
    result = response.get('result') if isinstance(response, dict) else None
    if (not isinstance(result, dict) or response.get('success') is not True or result.get('uuid') != uuid or
            result.get('transition_id') != enrollment['transition_id']):
        raise ConfirmationError('Target did not acknowledge protected transition enrollment')


def confirm_enrolled_host(target, ca_path, key_path, cert_path, inventory,
                          expected_uuid, expected_version, transition_id, timeout=15):
    cert, key = _load_identity(key_path, cert_path, expected_uuid)
    data, hashes, nonce = prepare_inventory(inventory, expected_uuid, expected_version, transition_id)
    response = _signed_post(target, ca_path, cert, key, '/update_host', data, timeout)
    verify_acknowledgement(response, expected_uuid, hashes, nonce, transition_id)
    return hashes['host_info']
