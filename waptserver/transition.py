# -*- coding: utf-8 -*-
"""Read-back verification for signed PADIT transition inventory."""

import datetime
import hashlib
import json
import re
import struct
import time
from urlparse import urlsplit


SECTIONS = ('host_info', 'wapt_status')
NONCE_FIELD = 'padit_transition_confirmation'
PROVISIONAL_SECONDS = 24 * 60 * 60
GUID = re.compile(r'\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z', re.I)
DNS = re.compile(r'\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.?\Z', re.I)


def identity_key(uuid):
    if not isinstance(uuid, basestring):
        uuid = unicode(uuid)
    candidate = uuid[1:-1] if uuid.startswith('{') and uuid.endswith('}') else uuid
    if GUID.match(candidate):
        return 'guid', candidate.lower()
    if DNS.match(uuid):
        return 'dns', uuid.rstrip('.').lower()
    return 'opaque', uuid


def advisory_key(uuid):
    kind, key = identity_key(uuid)
    return struct.unpack('!q', hashlib.sha256((kind + ':' + key).encode('utf-8')).digest()[:8])[0]


def transition_id(value):
    if isinstance(value, basestring) and value.startswith('{') and value.endswith('}'):
        value = value[1:-1]
    if not isinstance(value, basestring) or not GUID.match(value):
        raise ValueError('Invalid transition identifier')
    return value.lower()


def enrollment_trace(value):
    if not isinstance(value, dict) or set(value) != set(
            ('transition_id', 'source_server', 'source_version', 'target_version', 'issued_at')):
        raise ValueError('Invalid transition enrollment metadata')
    source = value['source_server']
    if not isinstance(source, basestring) or len(source) > 2048 or re.search(r'[\\@\s]', source):
        raise ValueError('Invalid transition source endpoint')
    url = urlsplit(source)
    if url.scheme not in ('https', 'http') or not url.hostname or url.query or url.fragment:
        raise ValueError('Invalid transition source endpoint')
    for name, pattern in (('source_version', r'\A1\.8\.[23]\.[0-9]+\Z'),
                          ('target_version', r'\A1\.8\.3\.[0-9]+\Z')):
        if not isinstance(value[name], basestring) or not re.match(pattern, value[name]):
            raise ValueError('Invalid transition version')
    issued = value['issued_at']
    now = int(time.time())
    if type(issued) not in (int, long) or issued < now - 300 or issued > now + 30:
        raise ValueError('Transition enrollment proof is outside its time window')
    return dict(value, transition_id=transition_id(value['transition_id']),
                state='provisional', confirmed_at=None, expires_at=now + PROVISIONAL_SECONDS)


def protection_active(trace, now):
    return bool(trace and trace['state'] == 'provisional' and
                now < trace.get('expires_at', trace['issued_at'] + PROVISIONAL_SECONDS))


def public_key(certificate):
    numbers = certificate.rsa.public_numbers()
    return numbers.n, numbers.e


def verify_proof(certificate, uuid, signed_request):
    if not signed_request or not signed_request[1] or identity_key(certificate.cn) != identity_key(uuid):
        raise ValueError('Transition requires proof with the host certificate')
    body, signature = signed_request
    certificate.verify_content(hashlib.sha256(body).hexdigest(), signature)


def protect_enrollment(current, requested, now):
    if current is None:
        return requested
    if current['transition_id'] == requested['transition_id']:
        if current['state'] == 'provisional' and not protection_active(current, now):
            raise ValueError('Provisional transition expired')
        if any(current[name] != requested[name] for name in ('source_server', 'source_version', 'target_version')):
            raise ValueError('Transition metadata differs from the protected enrollment')
        return current
    if protection_active(current, now):
        raise ValueError('A different transition is already provisionally protected')
    if requested['issued_at'] <= current['issued_at']:
        raise ValueError('Transition enrollment predates the existing protection')
    last_confirmed = current if current['state'] == 'confirmed' else current.get('last_confirmed')
    return dict(requested, last_confirmed=last_confirmed) if last_confirmed else requested


def confirm_trace(current, received_id, version, now=None):
    if (not current or current['transition_id'] != transition_id(received_id) or
            current['target_version'] != version):
        raise ValueError('Inventory does not match the protected transition')
    if current['state'] == 'confirmed':
        return current
    if now is None:
        now = int(time.time())
    if not protection_active(current, now):
        raise ValueError('Provisional transition expired')
    confirmed = dict(current, state='confirmed',
                     confirmed_at=datetime.datetime.utcfromtimestamp(now).strftime('%Y-%m-%dT%H:%M:%SZ'))
    confirmed.pop('expires_at', None)
    confirmed.pop('last_confirmed', None)
    return confirmed


def guard_identity(candidates, uuid, data, enrollment, confirmation_nonce, signed_request, certificate):
    # Call only after obtaining the transaction's UUID lock and selecting the rows.
    tracking = enrollment is not None or confirmation_nonce is not None
    now = int(time.time())
    protected = any(protection_active(host.padit_transition, now) for host in candidates)
    host = None
    if tracking or protected:
        if len(candidates) > 1:
            raise ValueError('Ambiguous UUID aliases for protected enrollment')
        if candidates:
            host = candidates[0]
            if not host.host_certificate:
                raise ValueError('Existing protected or transition identity has no certificate')
            known = certificate(crt_string=host.host_certificate)
            if tracking or 'host_certificate' in data or uuid != host.uuid:
                verify_proof(known, uuid, signed_request)
            if 'host_certificate' in data:
                supplied = certificate(crt_string=data['host_certificate'])
                if public_key(known) != public_key(supplied):
                    raise ValueError('Existing UUID has a different public key')
                del data['host_certificate']
    trace = host.padit_transition if host else None
    if enrollment is not None:
        if host is None:
            verify_proof(certificate(crt_string=data['host_certificate']), uuid, signed_request)
        requested = protect_enrollment(trace, enrollment, now)
        if requested is trace:
            return host.uuid, trace, True
        trace = requested
        if host:
            data.pop('host_info', None)
    elif confirmation_nonce is not None:
        if not host:
            raise ValueError('Confirmation requires an enrolled identity')
        trace = confirm_trace(trace, data.get('transition_id'), data['wapt_status']['wapt-get-version'], now)
    return host.uuid if host else uuid, trace, False


def transition_nonce(data):
    sections = [data.get(name) for name in SECTIONS]
    present = [isinstance(section, dict) and NONCE_FIELD in section for section in sections]
    if not any(present):
        return None
    if not all(present):
        raise ValueError('Transition inventory requires both confirmation sections')
    first, second = [section[NONCE_FIELD] for section in sections]
    if not isinstance(first, basestring) or not re.match(r'\A[a-f0-9]{32}\Z', first) or first != second:
        raise ValueError('Invalid transition inventory nonce')
    version = sections[1].get('wapt-get-version')
    if not isinstance(version, basestring) or not re.match(r'\A1\.8\.3\.[0-9]+\Z', version):
        raise ValueError('Invalid transition inventory version')
    return first


def inventory_readback(signed, stored, nonce):
    """Recompute acknowledgement from fields selected back inside the write transaction."""
    if not nonce or transition_nonce(signed) != nonce or transition_nonce(stored) != nonce:
        raise ValueError('The stored inventory does not contain this transition nonce')
    if identity_key(signed['uuid']) != identity_key(stored['uuid']):
        raise ValueError('Stored transition UUID differs from the signed UUID')
    hashes = {}
    for name in SECTIONS:
        incoming = json.dumps(signed[name], sort_keys=True, separators=(',', ':'), ensure_ascii=True)
        persisted = json.dumps(stored[name], sort_keys=True, separators=(',', ':'), ensure_ascii=True)
        if incoming != persisted:
            raise ValueError('Stored transition inventory differs from the signed inventory')
        hashes[name] = hashlib.sha256(persisted).hexdigest()
    return dict(nonce=nonce, uuid=signed['uuid'], inventory_sha256=hashes)
