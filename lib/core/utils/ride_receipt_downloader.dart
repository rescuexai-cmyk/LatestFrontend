import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/ride.dart';

/// Builds and shares a downloadable PDF ride receipt.
class RideReceiptDownloader {
  RideReceiptDownloader._();

  static Future<void> downloadAndShare({
    required Ride ride,
    Map<String, dynamic>? apiReceipt,
  }) async {
    final data = _normalize(apiReceipt, ride);
    final doc = pw.Document();
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    final dateFmt = DateFormat('dd MMM yyyy • hh:mm a');

    String money(dynamic v) {
      final n = _toDouble(v);
      return currency.format(n);
    }

    String date(dynamic v) {
      final d = _parseDate(v) ?? ride.createdAt;
      return dateFmt.format(_toIst(d));
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Raahi',
                        style: pw.TextStyle(
                          fontSize: 28,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#D4956A'),
                        ),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'Ride Receipt',
                        style: pw.TextStyle(
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        data['receiptNumber']?.toString() ??
                            'RCP-${ride.id.substring(0, 8).toUpperCase()}',
                        style: pw.TextStyle(
                          fontSize: 12,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        date(data['createdAt']),
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
              pw.SizedBox(height: 16),
              pw.Divider(),
              pw.SizedBox(height: 12),
              _kv('Ride ID', ride.id),
              _kv('Status', (data['status'] ?? ride.status.name)
                  .toString()
                  .toUpperCase()),
              _kv('Vehicle', (data['vehicleType'] ?? ride.rideType)
                  .toString()
                  .toUpperCase()),
              _kv('Payment', (data['paymentMethod'] ?? ride.paymentMethod.name)
                  .toString()
                  .toUpperCase()),
              if (data['driverName'] != null)
                _kv('Driver', data['driverName'].toString()),
              if (data['vehicleNumber'] != null)
                _kv('Vehicle no.', data['vehicleNumber'].toString()),
              pw.SizedBox(height: 14),
              pw.Text(
                'Route',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              _kv('Pickup', data['pickup']?.toString() ?? '—'),
              _kv('Drop-off', data['drop']?.toString() ?? '—'),
              pw.SizedBox(height: 14),
              pw.Text(
                'Trip',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              _kv(
                'Distance',
                '${(_toDouble(data['distance'] ?? ride.distance)).toStringAsFixed(1)} km',
              ),
              _kv(
                'Duration',
                '${data['duration'] ?? ride.estimatedDuration} min',
              ),
              pw.SizedBox(height: 14),
              pw.Text(
                'Fare breakdown',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              _kv('Base fare', money(data['baseFare'])),
              _kv('Distance fare', money(data['distanceFare'])),
              _kv('Time fare', money(data['timeFare'])),
              if (_toDouble(data['surgeMultiplier'], 1) > 1.01)
                _kv(
                  'Surge (${_toDouble(data['surgeMultiplier'], 1).toStringAsFixed(1)}x)',
                  money(data['surgeAmount']),
                ),
              pw.Divider(),
              pw.SizedBox(height: 4),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Total',
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    money(data['totalFare'] ?? ride.fare),
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColor.fromHex('#1A1A1A'),
                    ),
                  ),
                ],
              ),
              pw.Spacer(),
              pw.Divider(),
              pw.SizedBox(height: 8),
              pw.Text(
                'Thank you for riding with Raahi.\nCurated with love in Delhi, NCR.',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
              ),
            ],
          );
        },
      ),
    );

    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final shortId = ride.id.length > 8 ? ride.id.substring(0, 8) : ride.id;
    final file = File('${dir.path}/Raahi_Receipt_$shortId.pdf');
    await file.writeAsBytes(bytes, flush: true);

    await Share.shareXFiles(
      [
        XFile(
          file.path,
          mimeType: 'application/pdf',
          name: 'Raahi_Receipt_$shortId.pdf',
        ),
      ],
      subject: 'Raahi ride receipt',
      text: 'Your Raahi ride receipt ($shortId)',
    );
  }

  static pw.Widget _kv(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 110,
            child: pw.Text(
              label,
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              value,
              style: const pw.TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  static Map<String, dynamic> _normalize(
    Map<String, dynamic>? apiReceipt,
    Ride ride,
  ) {
    Map<String, dynamic> raw = {};
    if (apiReceipt != null) {
      final data = apiReceipt['data'];
      if (data is Map) {
        raw = Map<String, dynamic>.from(data);
      } else {
        raw = Map<String, dynamic>.from(apiReceipt);
      }
    }

    final fare = raw['fare'];
    final fareMap = fare is Map ? Map<String, dynamic>.from(fare) : <String, dynamic>{};
    final driver = raw['driver'];
    final driverMap =
        driver is Map ? Map<String, dynamic>.from(driver) : <String, dynamic>{};
    final pickup = raw['pickup'];
    final drop = raw['drop'] ?? raw['dropoff'];
    final timestamps = raw['timestamps'];
    final tsMap = timestamps is Map
        ? Map<String, dynamic>.from(timestamps)
        : <String, dynamic>{};

    String? addressOf(dynamic loc) {
      if (loc is Map) return loc['address']?.toString();
      return loc?.toString();
    }

    final fb = ride.fareBreakdown ?? {};

    return {
      'receiptNumber': raw['receiptNumber'],
      'status': raw['status'] ?? ride.status.name,
      'vehicleType': raw['vehicleType'] ?? ride.rideType,
      'paymentMethod': raw['paymentMethod'] ?? ride.paymentMethod.name,
      'driverName': driverMap['name'] ?? ride.driver?.name,
      'vehicleNumber':
          driverMap['vehicleNumber'] ?? ride.driver?.vehicleInfo?.plateNumber,
      'pickup': addressOf(pickup) ?? ride.pickupLocation.address,
      'drop': addressOf(drop) ?? ride.destinationLocation.address,
      'distance': raw['distance'] ?? ride.distance,
      'duration': raw['duration'] ?? ride.estimatedDuration,
      'baseFare': fareMap['baseFare'] ?? fb['baseFare'] ?? fb['startingFee'],
      'distanceFare': fareMap['distanceFare'] ?? fb['distanceFare'],
      'timeFare': fareMap['timeFare'] ?? fb['timeFare'],
      'surgeMultiplier':
          fareMap['surgeMultiplier'] ?? fb['surgeMultiplier'] ?? 1,
      'surgeAmount': fareMap['surgeFare'] ?? fb['surgeAmount'] ?? 0,
      'totalFare':
          fareMap['totalFare'] ?? raw['fare'] ?? raw['total'] ?? ride.fare,
      'createdAt':
          tsMap['created'] ?? raw['created_at'] ?? ride.createdAt.toIso8601String(),
    };
  }

  static double _toDouble(dynamic v, [double fallback = 0]) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? fallback;
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    try {
      return DateTime.parse(v.toString());
    } catch (_) {
      return null;
    }
  }

  static DateTime _toIst(DateTime value) {
    final utc = value.isUtc ? value : value.toUtc();
    return utc.add(const Duration(hours: 5, minutes: 30));
  }
}
