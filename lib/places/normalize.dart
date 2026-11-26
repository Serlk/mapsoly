/// Text normalisation for offline search (query time).
///
/// Mirrors `tool/places/ru_normalize.py` (index time) rule for rule; both are
/// checked against `test/places/normalize_cases.json`. The rules are described
/// in `docs/places.md`. Bump [normVersion] on both sides when changing them.
library;

const int normVersion = 1;

/// Hyphenated abbreviations, replaced before punctuation is dropped.
const Map<String, String> hyphenAbbreviations = {
  'пр-т': 'проспект',
  'пр-кт': 'проспект',
  'пр-д': 'проезд',
  'б-р': 'бульвар',
  'р-н': 'район',
  'мкр-н': 'микрорайон',
  'м-н': 'микрорайон',
  'ш-се': 'шоссе',
  'пл-дь': 'площадь',
  'наб-я': 'набережная',
  'ул-ца': 'улица',
  'п-к': 'переулок',
};

/// Whole-token abbreviations.
const Map<String, String> tokenAbbreviations = {
  'ул': 'улица',
  'пр': 'проспект',
  'просп': 'проспект',
  'пркт': 'проспект',
  'пер': 'переулок',
  'ш': 'шоссе',
  'пл': 'площадь',
  'бул': 'бульвар',
  'бульв': 'бульвар',
  'наб': 'набережная',
  'туп': 'тупик',
  'прд': 'проезд',
  'ал': 'аллея',
  'д': 'дом',
  'к': 'корпус',
  'корп': 'корпус',
  'стр': 'строение',
  'г': 'город',
  'гор': 'город',
  'п': 'поселок',
  'пос': 'поселок',
  'дер': 'деревня',
  'мкр': 'микрорайон',
  'мкрн': 'микрорайон',
  'обл': 'область',
  'им': 'имени',
};

/// Status words: optional in a query (they only boost matching names).
const Set<String> genericWords = {
  'улица',
  'проспект',
  'переулок',
  'шоссе',
  'площадь',
  'бульвар',
  'набережная',
  'тупик',
  'проезд',
  'аллея',
  'город',
  'поселок',
  'деревня',
  'село',
  'микрорайон',
  'район',
  'область',
  'дом',
};

const String _l = 'a-zа-я';
final RegExp _hyphenRe = RegExp(
  '(?<![${_l}0-9])(${(hyphenAbbreviations.keys.toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|')})(?![${_l}0-9])',
);
final RegExp _ordHyphenRe = RegExp(
  '([0-9]+)\\s*-\\s*(?:ая|ый|ой|ий|ое|ья|ей|ые|го|я|й|е|х|м)(?![${_l}0-9])',
);
final RegExp _ordGluedRe = RegExp(
  '(?<![${_l}0-9])([0-9]+)(?:ая|ый|ой|ий|ое|я|й)(?![${_l}0-9])',
);
final RegExp _markRe = RegExp(r'\p{M}', unicode: true);
final RegExp _tokenRe = RegExp(r'[\p{L}\p{N}]+', unicode: true);
final RegExp _tokenSlashRe = RegExp(r'[\p{L}\p{N}/]+', unicode: true);

String _fold(String text) => text
    .toLowerCase()
    .replaceAll('й', 'й')
    .replaceAll('ё', 'е')
    .replaceAll('ё', 'е');

/// Normalised tokens of [text]. With [keepSlash] a `/` inside a token is
/// preserved ("5/7"), which the query parser needs to recognise house numbers.
///
/// [expand] = false skips the whole-token abbreviation table (query parser
/// only: the raw form of a half-typed last word).
List<String> normalizeTokens(
  String text, {
  bool keepSlash = false,
  bool expand = true,
}) {
  final fast = _fastTokens(text, keepSlash, expand);
  if (fast != null) return fast;
  var s = _fold(text).replaceAll(_markRe, '');
  s = s.replaceAllMapped(
    _hyphenRe,
    (m) => ' ${hyphenAbbreviations[m.group(1)]} ',
  );
  s = s.replaceAllMapped(_ordHyphenRe, (m) => '${m.group(1)} ');
  s = s.replaceAllMapped(_ordGluedRe, (m) => '${m.group(1)} ');
  final out = <String>[];
  for (final m in (keepSlash ? _tokenSlashRe : _tokenRe).allMatches(s)) {
    var t = m.group(0)!;
    if (keepSlash) {
      t = t.replaceAll(RegExp(r'^/+|/+$'), '');
      if (t.isEmpty) continue;
    }
    out.add(expand ? (tokenAbbreviations[t] ?? t) : t);
  }
  return out;
}

/// Fast path of [normalizeTokens] for plain Latin/Cyrillic text without
/// hyphens or digit+letter runs; returns null when the general (regex) path
/// is needed. Must produce exactly what the general path would.
List<String>? _fastTokens(String text, bool keepSlash, bool expand) {
  final out = <String>[];
  final buf = <int>[];
  var lastDigit = false;
  void flush() {
    if (buf.isEmpty) return;
    final t = String.fromCharCodes(buf);
    buf.clear();
    out.add(expand ? (tokenAbbreviations[t] ?? t) : t);
  }

  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    int m;
    var digit = false;
    if (c >= 0x30 && c <= 0x39) {
      m = c;
      digit = true;
    } else if (c >= 0x61 && c <= 0x7a) {
      m = c;
    } else if (c >= 0x41 && c <= 0x5a) {
      m = c | 0x20;
    } else if (c >= 0x430 && c <= 0x44f) {
      m = c;
    } else if (c >= 0x410 && c <= 0x42f) {
      m = c + 0x20;
    } else if (c == 0x401 || c == 0x451) {
      m = 0x435; // Ё, ё → е
    } else if (c == 0x2d || (c == 0x2f && keepSlash)) {
      return null; // hyphen rules / slash handling: general path
    } else if (c < 0x80 || c == 0xab || c == 0xbb || c == 0xa0 || c == 0x2116) {
      m = 0; // ASCII punctuation, «», NBSP, №
    } else {
      return null;
    }
    if (m == 0) {
      flush();
    } else {
      // "3я" (glued ordinal) is handled by the general path.
      if (!digit && lastDigit && m >= 0x430 && buf.isNotEmpty) return null;
      buf.add(m);
    }
    lastDigit = digit && m != 0;
  }
  flush();
  return out;
}

/// Normalised form of [text]: tokens joined by single spaces.
String normalizeText(String text) => normalizeTokens(text).join(' ');

final RegExp _hnTokRe = RegExp('[0-9]+|[$_l]+|[/-]');
const Map<String, String> _hnWords = {
  'корпус': 'к',
  'корп': 'к',
  'кор': 'к',
  'к': 'к',
  'строение': 'с',
  'стр': 'с',
  'с': 'с',
  'литера': 'л',
  'литер': 'л',
  'лит': 'л',
};
const Set<String> _hnDrop = {'дом', 'д', 'владение', 'вл', 'домовладение'};

bool _isDigit(String s) {
  if (s.isEmpty) return false;
  final c = s.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

/// Canonical house number: "12 корп. 1 стр 2" → "12к1с2", "5 А" → "5а".
/// Returns '' when the text contains no digit.
String normalizeHouseNumber(String text) {
  final out = <String>[];
  var seenDigit = false;
  for (final m in _hnTokRe.allMatches(_fold(text))) {
    final t = m.group(0)!;
    if (_isDigit(t)) {
      seenDigit = true;
      out.add(t);
    } else if (t == '/' || t == '-') {
      if (out.isNotEmpty && out.last != '/' && out.last != '-') out.add(t);
    } else if (!seenDigit && _hnDrop.contains(t)) {
      continue;
    } else {
      out.add(_hnWords[t] ?? t);
    }
  }
  while (out.isNotEmpty && (out.last == '/' || out.last == '-')) {
    out.removeLast();
  }
  return seenDigit ? out.join() : '';
}

/// Human form of a canonical house number: "12к1с2" → "12 к1 с2", "5а" → "5А".
String displayHouseNumber(String hn) {
  final sb = StringBuffer();
  bool isAlpha(String c) =>
      c.isNotEmpty && !_isDigit(c) && c != '/' && c != '-';
  for (var i = 0; i < hn.length; i++) {
    final ch = hn[i];
    final next = i + 1 < hn.length ? hn[i + 1] : '';
    final prev = i > 0 ? hn[i - 1] : '';
    if ((ch == 'к' || ch == 'с') && _isDigit(next) && prev.isNotEmpty) {
      sb.write(' $ch');
    } else if (isAlpha(ch) && _isDigit(prev)) {
      sb.write(ch.toUpperCase());
    } else {
      sb.write(ch);
    }
  }
  return sb.toString();
}

/// One way to read a query: free-text [tokens] plus an optional [house].
class QueryReading {
  const QueryReading(
    this.tokens,
    this.house, {
    required this.lastIsPrefix,
    this.houseIsPrefix = false,
    this.lastRaw,
  });

  /// Text tokens (normalised, in query order).
  final List<String> tokens;

  /// Canonical house number, or null for a plain text reading.
  final String? house;

  /// Whether the last text token is still being typed (prefix match).
  final bool lastIsPrefix;

  /// When the half-typed last token was expanded as an abbreviation ("п" →
  /// "поселок"), its raw form, so that it can also be matched as a prefix.
  final String? lastRaw;

  /// Whether the house number is the last, possibly unfinished, word.
  final bool houseIsPrefix;
}

final RegExp _houseStartRe = RegExp('^[0-9]+[$_l]?(?:[/-][0-9]+[$_l]?)?\$');
final RegExp _houseFullRe = RegExp('^[0-9]+[$_l]?(?:[кс][0-9]+)+\$');
final RegExp _unitRe = RegExp(r'^[кс][0-9]+$');
final RegExp _singleLetterRe = RegExp('^[$_l]\$');
final RegExp _digitsRe = RegExp(r'^[0-9]+$');
final RegExp _typingRe = RegExp(r'[\p{L}\p{N}]$', unicode: true);

/// Parses a raw query into its possible readings: the plain text reading
/// first, then readings where one numeric token is taken as a house number
/// ("ленина 5", "5 ленина", "ул. Ленина, д. 5 к2").
List<QueryReading> parseQuery(String query) {
  final raw = normalizeTokens(query, keepSlash: true);
  final typing = _typingRe.hasMatch(query);
  final plain = <String>[
    for (final t in raw) ...t.split('/').where((p) => p.isNotEmpty),
  ];
  final unexpanded = normalizeTokens(query, keepSlash: true, expand: false);
  String? rawOf(List<String> toks, bool prefix) =>
      prefix &&
          toks.isNotEmpty &&
          unexpanded.isNotEmpty &&
          tokenAbbreviations[unexpanded.last] == toks.last
      ? unexpanded.last
      : null;
  final readings = <QueryReading>[
    QueryReading(
      plain,
      null,
      lastIsPrefix: typing,
      lastRaw: rawOf(plain, typing),
    ),
  ];
  if (raw.length < 2) return readings;
  final starts = <int>[];
  for (var i = raw.length - 1; i >= 0; i--) {
    // "корпус 2", "стр 1": the number of a building unit, not a house.
    final unit =
        i > 0 &&
        (raw[i - 1] == 'корпус' ||
            raw[i - 1] == 'строение' ||
            raw[i - 1] == 'с');
    if (!unit &&
        (_houseStartRe.hasMatch(raw[i]) || _houseFullRe.hasMatch(raw[i]))) {
      starts.add(i);
    }
  }
  for (final i in starts.take(2)) {
    var j = i + 1;
    final parts = <String>[raw[i]];
    while (j < raw.length) {
      final t = raw[j];
      final next = j + 1 < raw.length ? raw[j + 1] : null;
      if ((t == 'корпус' || t == 'строение' || t == 'с') &&
          next != null &&
          _digitsRe.hasMatch(next)) {
        parts.add('${t == 'корпус' ? 'к' : 'с'}$next');
        j += 2;
      } else if (_unitRe.hasMatch(t)) {
        parts.add(t);
        j++;
      } else if (parts.length == 1 &&
          _digitsRe.hasMatch(raw[i]) &&
          _singleLetterRe.hasMatch(t) &&
          j == raw.length - 1) {
        // "ленина 5 а" – a trailing single letter belongs to the number.
        parts.add(t);
        j++;
      } else {
        break;
      }
    }
    final house = normalizeHouseNumber(parts.join(' '));
    if (house.isEmpty) continue;
    final text = <String>[
      for (var k = 0; k < raw.length; k++)
        if ((k < i || k >= j) && raw[k] != 'дом')
          ...raw[k].split('/').where((p) => p.isNotEmpty),
    ];
    if (text.isEmpty) continue;
    final houseAtEnd = j == raw.length;
    readings.add(
      QueryReading(
        text,
        house,
        lastIsPrefix: typing && !houseAtEnd,
        houseIsPrefix: typing && houseAtEnd,
        lastRaw: rawOf(text, typing && !houseAtEnd),
      ),
    );
  }
  return readings;
}
