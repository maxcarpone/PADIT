from .core import encode, decode, alabel, ulabel, IDNAError
import codecs
import re

_unicode_dots_re = re.compile(u'[\u002e\u3002\uff0e\uff61]')

class Codec(codecs.Codec):

    def encode(self, data, errors='strict'):

        if errors != 'strict':
            raise IDNAError("Unsupported error handling \"{0}\"".format(errors))

        if not data:
            return "", 0

        return encode(data), len(data)

    def decode(self, data, errors='strict'):

        if errors != 'strict':
            raise IDNAError("Unsupported error handling \"{0}\"".format(errors))

        if not data:
            return u"", 0

        return decode(data), len(data)

class IncrementalEncoder(codecs.BufferedIncrementalEncoder):
    def __init__(self, errors='strict'):
        codecs.BufferedIncrementalEncoder.__init__(self, errors)
        self._emitted = 0
        self._trailing_dot = False

    def reset(self):
        codecs.BufferedIncrementalEncoder.reset(self)
        self._emitted = 0
        self._trailing_dot = False

    def getstate(self):
        # Follow upstream idna: preserve the standard initial state.
        if not self.buffer and not self._emitted:
            return 0
        return (self.buffer, self._emitted, self._trailing_dot)

    def setstate(self, state):
        if not state:
            self.reset()
        else:
            if not isinstance(state, tuple) or len(state) != 3:
                raise ValueError('Invalid incremental IDNA encoder state')
            self.buffer, self._emitted, self._trailing_dot = state

    def _buffer_encode(self, data, errors, final):
        if errors != 'strict':
            raise IDNAError("Unsupported error handling \"{0}\"".format(errors))

        if not data:
            return ("", 0)

        labels = _unicode_dots_re.split(data)
        trailing_dot = u''
        if labels:
            if not labels[-1]:
                trailing_dot = '.'
                del labels[-1]
            elif not final:
                # Keep potentially unfinished label until the next call
                del labels[-1]
                if labels:
                    trailing_dot = '.'

        result = []
        size = 0
        for label in labels:
            result.append(alabel(label))
            if size:
                size += 1
            size += len(label)

        # Join with U+002E
        result = ".".join(result) + trailing_dot
        size += len(trailing_dot)

        new_total = self._emitted + len(result)
        ends_with_dot = result.endswith('.')
        if not result:
            ends_with_dot = self._trailing_dot

        limit = 254 if (ends_with_dot or not final) else 253
        if new_total > limit:
            raise IDNAError('Domain too long')

        self._emitted = new_total
        self._trailing_dot = ends_with_dot
        return (result, size)

class IncrementalDecoder(codecs.BufferedIncrementalDecoder):
    def __init__(self, errors='strict'):
        codecs.BufferedIncrementalDecoder.__init__(self, errors)
        self._consumed = 0
        self._trailing_dot = False

    def reset(self):
        codecs.BufferedIncrementalDecoder.reset(self)
        self._consumed = 0
        self._trailing_dot = False

    def getstate(self):
        # Preserve the Python 2 buffered decoder state shape.
        # Bit 256 records the trailing-dot flag.
        flags = 256 if self._trailing_dot else 0
        return (self.buffer, self._consumed | flags)

    def setstate(self, state):
        buffer, value = state
        if not isinstance(value, (int, long)) or value < 0 or value > 510:
            raise ValueError('Invalid incremental IDNA decoder state')
        self.buffer = buffer
        self._consumed = value & 255
        self._trailing_dot = bool(value & 256)

    def _buffer_decode(self, data, errors, final):
        if errors != 'strict':
            raise IDNAError("Unsupported error handling \"{0}\"".format(errors))

        if not data:
            # A final empty call must still enforce the domain limit.
            if final and self._consumed > 253 and not self._trailing_dot:
                raise IDNAError('Domain too long')
            return (u"", 0)

        # Include buffered input without counting it twice.
        # A complete domain may contain 254 characters only when
        # it ends with a recognized IDNA dot separator.
        total_length = self._consumed + len(data)
        if total_length > 254:
            raise IDNAError('Domain too long')
        if final and total_length > 253:
            if not _unicode_dots_re.search(data[-1:]):
                raise IDNAError('Domain too long')

        # IDNA allows decoding to operate on Unicode strings, too.
        if isinstance(data, unicode):
            labels = _unicode_dots_re.split(data)
        else:
            # Must be ASCII string
            data = str(data)
            unicode(data, "ascii")
            labels = data.split(".")

        trailing_dot = u''
        if labels:
            if not labels[-1]:
                trailing_dot = u'.'
                del labels[-1]
            elif not final:
                # Keep potentially unfinished label until the next call
                del labels[-1]
                if labels:
                    trailing_dot = u'.'

        result = []
        size = 0
        for label in labels:
            result.append(ulabel(label))
            if size:
                size += 1
            size += len(label)

        result = u".".join(result) + trailing_dot
        size += len(trailing_dot)

        # Only consumed input contributes to the persistent counter.
        self._consumed += size
        if result:
            self._trailing_dot = result.endswith(u'.')
        return (result, size)


class StreamWriter(Codec, codecs.StreamWriter):
    pass

class StreamReader(Codec, codecs.StreamReader):
    pass

def getregentry():
    return codecs.CodecInfo(
        name='idna',
        encode=Codec().encode,
        decode=Codec().decode,
        incrementalencoder=IncrementalEncoder,
        incrementaldecoder=IncrementalDecoder,
        streamwriter=StreamWriter,
        streamreader=StreamReader,
    )
