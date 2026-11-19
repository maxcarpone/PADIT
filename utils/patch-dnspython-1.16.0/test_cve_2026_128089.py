import unittest

import dns.rdata
import dns.rdataclass
import dns.rdatatype
from dns.rdtypes.IN import WKS


def parse_wks(protocol, services):
    text = '192.0.2.1 %s %s' % (protocol, services)
    return dns.rdata.from_text(dns.rdataclass.IN, dns.rdatatype.WKS, text)


class WKSServiceBoundsTest(unittest.TestCase):
    def test_zero(self):
        self.assertEqual(parse_wks('udp', '0').bitmap, bytearray(b'\x80'))

    def test_highest_service(self):
        bitmap = parse_wks('udp', '0 65535 0').bitmap
        self.assertEqual(bitmap, bytearray(b'\x80' + b'\x00' * 8190 + b'\x01'))

    def test_first_out_of_range_service(self):
        self.assertRaisesRegexp(ValueError, 'service must be between',
                                parse_wks, 'udp', '65536')

    def test_large_service_rejected_before_bitmap_access(self):
        class UntouchedBitmap(bytearray):
            def __len__(self):
                raise AssertionError('service reached bitmap size calculation')

        # Fail immediately even if the parser's bounds check regresses.
        WKS.bytearray = UntouchedBitmap
        try:
            self.assertRaisesRegexp(ValueError, 'service must be between',
                                    parse_wks, 'udp', str(10 ** 30))
        finally:
            del WKS.bytearray

    def test_named_services(self):
        lookup = WKS.socket.getservbyname
        calls = []

        def getservbyname(service, protocol):
            calls.append((service, protocol))
            return {'http': 80, 'domain': 53, 'out-of-range': -1}[service]

        WKS.socket.getservbyname = getservbyname
        try:
            self.assertEqual(parse_wks('tcp', 'http 0').bitmap,
                             parse_wks('tcp', '80 0').bitmap)
            self.assertEqual(parse_wks('17', 'domain').bitmap,
                             parse_wks('udp', '53').bitmap)
            self.assertRaisesRegexp(ValueError, 'service must be between',
                                    parse_wks, 'udp', 'out-of-range')
        finally:
            WKS.socket.getservbyname = lookup
        self.assertEqual(calls, [('http', 'tcp'), ('domain', 'udp'),
                                 ('out-of-range', 'udp')])

    def test_bitmap_size_limit(self):
        args = (dns.rdataclass.IN, dns.rdatatype.WKS, '192.0.2.1', 17)
        for size in (0, 8192):
            record = WKS.WKS(*(args + (bytearray(size),)))
            self.assertEqual(len(record.bitmap), size)
        self.assertRaises(ValueError, WKS.WKS, *(args + (bytearray(8193),)))


if __name__ == '__main__':
    unittest.main()
