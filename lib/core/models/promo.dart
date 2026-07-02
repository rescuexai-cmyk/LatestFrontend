/// Promo / coupon code available to the user.
///
/// Mirrors the backend `GET /api/promo/active` item shape and the server-side
/// discount math (`calculatePromoDiscount` in pricing-service/promoService).
/// The authoritative discount is always computed by the backend at booking time;
/// [computeDiscount] is only used to preview the saving in the UI.
enum PromoType { percent, flat, cashback }

class Promo {
  final String code;
  final String description;
  final PromoType type;
  final double value;
  final double? maxDiscount;
  final double? minFare;

  const Promo({
    required this.code,
    required this.description,
    required this.type,
    required this.value,
    this.maxDiscount,
    this.minFare,
  });

  static PromoType _parseType(dynamic raw) {
    switch (raw?.toString().toUpperCase()) {
      case 'FLAT':
        return PromoType.flat;
      case 'CASHBACK':
        return PromoType.cashback;
      case 'PERCENT':
      default:
        return PromoType.percent;
    }
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  static double? _toDoubleOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  factory Promo.fromJson(Map<String, dynamic> json) {
    return Promo(
      code: (json['code'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      type: _parseType(json['type']),
      value: _toDouble(json['value']),
      maxDiscount: _toDoubleOrNull(json['maxDiscount']),
      minFare: _toDoubleOrNull(json['minFare']),
    );
  }

  bool get isCashback => type == PromoType.cashback;

  /// Whether the promo can apply to a trip of [fare] (min-fare gate only; the
  /// full eligibility check is always enforced server-side at booking).
  bool meetsMinFare(double fare) => minFare == null || fare >= minFare!;

  /// Preview of the upfront discount for [fare].
  ///
  /// Matches the backend: PERCENT is capped by [maxDiscount], FLAT is capped by
  /// the fare, and CASHBACK gives no upfront discount (see [cashbackAmount]).
  double computeDiscount(double fare) {
    if (fare <= 0) return 0;
    switch (type) {
      case PromoType.percent:
        var amount = fare * value / 100;
        if (maxDiscount != null && amount > maxDiscount!) amount = maxDiscount!;
        return _round2(amount);
      case PromoType.flat:
        return _round2(value < fare ? value : fare);
      case PromoType.cashback:
        return 0;
    }
  }

  /// Cashback earned later (0 for non-cashback promos), capped by [maxDiscount].
  double cashbackAmount(double fare) {
    if (type != PromoType.cashback) return 0;
    var amount = value;
    if (maxDiscount != null && amount > maxDiscount!) amount = maxDiscount!;
    return _round2(amount);
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
