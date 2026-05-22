// Run: dart run tool/migrate_app_messenger.dart
// Converts simple ScaffoldMessenger.showSnackBar(SnackBar(content: Text(x))) to AppMessenger.

import 'dart:io';

void main() {
  final root = Directory.current;
  final lib = Directory('${root.path}/lib');
  if (!lib.existsSync()) {
    stderr.writeln('lib/ not found');
    exit(1);
  }
  var n = 0;
  for (final ent in lib.listSync(recursive: true, followLinks: false)) {
    if (ent is! File || !ent.path.endsWith('.dart')) continue;
    if (processFile(ent)) {
      stdout.writeln('updated: ${ent.path}');
      n++;
    }
  }
  stdout.writeln('Files changed: $n');
}

bool processFile(File path) {
  var text = path.readAsStringSync();
  if (!text.contains('showSnackBar')) return false;

  final spans = extractShowSnackBarSpans(text);
  if (spans.isEmpty) return false;

  final out = StringBuffer();
  var last = 0;
  var changed = false;
  for (final span in spans) {
    out.write(text.substring(last, span.start));
    final snippet = text.substring(span.start, span.end);
    final rep = tryConvert(snippet);
    if (rep != null) {
      out.write(rep);
      changed = true;
    } else {
      out.write(snippet);
    }
    last = span.end;
  }
  out.write(text.substring(last));

  if (!changed) return false;

  var newText = out.toString();
  if (!newText.contains('app_messenger.dart')) {
    newText = ensureImport(newText);
  }
  path.writeAsStringSync(newText);
  return true;
}

class Span {
  Span(this.start, this.end);
  final int start;
  final int end;
}

final _skipSnippet = RegExp(
  r'Colors\.green|AppColors\.success|0xFF4CAF50|#4CAF50|successfully|Rating submitted|saved!',
  caseSensitive: false,
);

List<Span> extractShowSnackBarSpans(String text) {
  final spans = <Span>[];
  const needle = 'ScaffoldMessenger.of(context).showSnackBar(';
  var pos = 0;
  while (true) {
    final start = text.indexOf(needle, pos);
    if (start == -1) break;
    final openParen = start + needle.length - 1;
    final close = findMatchingParen(text, openParen);
    if (close == null) {
      pos = start + 1;
      continue;
    }
    var end = close + 1;
    while (end < text.length && ' \t\r\n'.contains(text[end])) {
      end++;
    }
    if (end < text.length && text[end] == ';') end++;
    spans.add(Span(start, end));
    pos = end;
  }
  return spans;
}

int? findMatchingParen(String s, int openIdx) {
  var depth = 0;
  for (var i = openIdx; i < s.length; i++) {
    final c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

String? tryConvert(String fullCall) {
  if (fullCall.contains('SnackBarAction')) return null;

  final snackArg = getShowSnackBarArgument(fullCall);
  if (snackArg == null) return null;
  if (_skipSnippet.hasMatch(snackArg)) return null;

  final sbBody = getSnackBarWidgetBody(snackArg);
  if (sbBody == null) return null;

  final textExpr = extractTextExprAfterContent(sbBody);
  if (textExpr == null) return null;

  return 'AppMessenger.showErrorBanner(context, $textExpr);';
}

String? getShowSnackBarArgument(String fullCall) {
  final i = fullCall.indexOf('showSnackBar(');
  if (i < 0) return null;
  final openParen = i + 'showSnackBar('.length - 1;
  final close = findMatchingParen(fullCall, openParen);
  if (close == null) return null;
  return fullCall.substring(openParen + 1, close).trim();
}

String? getSnackBarWidgetBody(String snackArg) {
  var s = snackArg.trim();
  if (s.startsWith('const ')) {
    s = s.substring(6).trimLeft();
  }
  final idx = s.indexOf('SnackBar(');
  if (idx < 0) return null;
  final openParen = idx + 'SnackBar('.length - 1;
  final close = findMatchingParen(s, openParen);
  if (close == null) return null;
  return s.substring(openParen + 1, close).trim();
}

String? extractTextExprAfterContent(String sbBody) {
  final re = RegExp(r'content:\s*Text\s*\(');
  final m = re.firstMatch(sbBody);
  if (m == null) return null;
  final openAt = m.end - 1;
  final close = findMatchingParen(sbBody, openAt);
  if (close == null) return null;
  return sbBody.substring(openAt + 1, close).trim();
}

String ensureImport(String text) {
  const line =
      "import 'package:ride_hailing_flutter/core/widgets/app_messenger.dart';";
  final lines = text.split('\n');
  var insertAt = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('import ')) insertAt = i + 1;
  }
  lines.insert(insertAt, line);
  return lines.join('\n');
}
