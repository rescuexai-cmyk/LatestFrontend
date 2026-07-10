/// Shared INR fare rounding + display so rider sheet, payment, and driver
/// screens never disagree on the same amount.
library;

/// Round to paise (2 decimal places) — matches backend `round2`.
double roundFare(num? value) {
  if (value == null) return 0;
  return (value.toDouble() * 100).round() / 100;
}

/// Canonical fare string for UI. Always 2 decimals so ₹366.65 never becomes ₹367
/// on one tile and ₹366.65 on another.
String formatInrFare(num? value, {bool includeSymbol = true}) {
  final amount = roundFare(value);
  final body = amount.toStringAsFixed(2);
  return includeSymbol ? '₹$body' : body;
}

/// Parse a fare-like field from mixed API payloads.
double parseFare(dynamic raw) {
  if (raw == null) return 0;
  if (raw is num) return roundFare(raw);
  return roundFare(double.tryParse(raw.toString().trim()) ?? 0);
}
