"""Text normalisation shared by the places extractor (index time).

The Dart side (lib/places/normalize.dart) implements exactly the same rules
for query time.  Both are checked against test/places/normalize_cases.json.
Rules are documented in docs/places.md ("Normalisation"); bump NORM_VERSION
in both places when changing them.
"""
import re
import unicodedata

NORM_VERSION = 1

# Hyphenated abbreviations, replaced before punctuation is dropped.
HYPHEN_ABBR = {
    'пр-т': 'проспект', 'пр-кт': 'проспект', 'пр-д': 'проезд',
    'б-р': 'бульвар', 'р-н': 'район', 'мкр-н': 'микрорайон',
    'м-н': 'микрорайон', 'ш-се': 'шоссе', 'пл-дь': 'площадь',
    'наб-я': 'набережная', 'ул-ца': 'улица', 'п-к': 'переулок',
}
# Whole-token abbreviations.
TOKEN_ABBR = {
    'ул': 'улица', 'пр': 'проспект', 'просп': 'проспект',
    'пркт': 'проспект', 'пер': 'переулок', 'ш': 'шоссе', 'пл': 'площадь',
    'бул': 'бульвар', 'бульв': 'бульвар', 'наб': 'набережная',
    'туп': 'тупик', 'прд': 'проезд', 'ал': 'аллея', 'д': 'дом',
    'к': 'корпус', 'корп': 'корпус', 'стр': 'строение', 'г': 'город',
    'гор': 'город', 'п': 'поселок', 'пос': 'поселок', 'дер': 'деревня',
    'мкр': 'микрорайон', 'мкрн': 'микрорайон', 'обл': 'область',
    'им': 'имени',
}
# Ordinal suffixes dropped after a number: "1-я" -> "1", "2-й" -> "2".
ORD_HYPHEN = ('ая', 'ый', 'ой', 'ий', 'ое', 'ья', 'ей', 'ые', 'го', 'я', 'й',
              'е', 'х', 'м')
ORD_GLUED = ('ая', 'ый', 'ой', 'ий', 'ое', 'я', 'й')

_LETTERS = 'a-zа-я'
_HY = re.compile(
    r'(?<![%s0-9])(%s)(?![%s0-9])' % (
        _LETTERS,
        '|'.join(sorted((re.escape(k) for k in HYPHEN_ABBR), key=len,
                        reverse=True)),
        _LETTERS))
_ORD_H = re.compile(r'([0-9]+)\s*-\s*(?:%s)(?![%s0-9])'
                    % ('|'.join(ORD_HYPHEN), _LETTERS))
_ORD_G = re.compile(r'(?<![%s0-9])([0-9]+)(?:%s)(?![%s0-9])'
                    % (_LETTERS, '|'.join(ORD_GLUED), _LETTERS))


def _fold(text):
    s = text.lower()
    s = s.replace('й', 'й').replace('ё', 'е').replace('ё', 'е')
    return s


def _is_mark(ch):
    return unicodedata.category(ch)[0] == 'M'


def _is_alnum(ch):
    c = unicodedata.category(ch)[0]
    return c == 'L' or c == 'N'


def tokens(text, keep_slash=False):
    """Returns the list of normalised tokens of `text`."""
    s = _fold(text)
    s = ''.join(ch for ch in s if not _is_mark(ch))
    s = _HY.sub(lambda m: ' ' + HYPHEN_ABBR[m.group(1)] + ' ', s)
    s = _ORD_H.sub(r'\1 ', s)
    s = _ORD_G.sub(r'\1 ', s)
    out = []
    cur = []
    for ch in s:
        if _is_alnum(ch) or (keep_slash and ch == '/'):
            cur.append(ch)
        elif cur:
            out.append(''.join(cur))
            cur = []
    if cur:
        out.append(''.join(cur))
    res = []
    for t in out:
        if keep_slash:
            t = t.strip('/')
            if not t:
                continue
        res.append(TOKEN_ABBR.get(t, t))
    return res


def normalize(text):
    return ' '.join(tokens(text))


_HN_TOK = re.compile(r'[0-9]+|[a-zа-я]+|[/-]')
_HN_WORDS = {'корпус': 'к', 'корп': 'к', 'кор': 'к', 'к': 'к',
             'строение': 'с', 'стр': 'с', 'с': 'с',
             'литера': 'л', 'литер': 'л', 'лит': 'л'}
_HN_DROP = {'дом', 'д', 'владение', 'вл', 'домовладение'}


def normalize_housenumber(text):
    """Canonical house number: "12 корп. 1 стр 2" -> "12к1с2", "5 А" -> "5а".

    Returns '' when there is no digit in the result.
    """
    toks = _HN_TOK.findall(_fold(text))
    out = []
    seen_digit = False
    for t in toks:
        if t[0].isdigit():
            seen_digit = True
            out.append(t)
        elif t in '/-':
            if out and out[-1] not in ('/', '-'):
                out.append(t)
        elif not seen_digit and t in _HN_DROP:
            continue
        else:
            out.append(_HN_WORDS.get(t, t))
    while out and out[-1] in ('/', '-'):
        out.pop()
    s = ''.join(out)
    return s if seen_digit else ''


if __name__ == '__main__':
    import json
    import sys
    cases = json.load(open(sys.argv[1], encoding='utf-8'))
    bad = 0
    for c in cases['text']:
        got = normalize(c[0])
        if got != c[1]:
            bad += 1
            print('TEXT %r -> %r, want %r' % (c[0], got, c[1]))
    for c in cases['house']:
        got = normalize_housenumber(c[0])
        if got != c[1]:
            bad += 1
            print('HOUSE %r -> %r, want %r' % (c[0], got, c[1]))
    print('normalize cases: %d failed of %d'
          % (bad, len(cases['text']) + len(cases['house'])))
    sys.exit(1 if bad else 0)
