import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/marketing_banner.dart';
import '../models/promo.dart';
import '../services/api_client.dart';
import '../../features/ride/providers/ride_booking_provider.dart';

/// Active marketing banners for the services hub (`placement=HOME`).
///
/// Failures return an empty list so the hub never breaks when banners are
/// unavailable — the carousel section is simply hidden.
final homeMarketingBannersProvider =
    FutureProvider<List<MarketingBanner>>((ref) async {
  final city = inferPromoCity(ref.watch(rideBookingProvider).pickupAddress);
  final raw = await ref.read(apiClientProvider).getActiveBanners(
        placement: 'HOME',
        city: city,
      );
  return raw
      .map(MarketingBanner.fromJson)
      .where((b) => b.imageUrl.trim().isNotEmpty)
      .toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
});
