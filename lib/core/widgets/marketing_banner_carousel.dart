import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/marketing_banner.dart';

/// Auto-advancing horizontal banner carousel (320×120 slot).
class MarketingBannerCarousel extends StatefulWidget {
  final List<MarketingBanner> banners;
  final ValueChanged<MarketingBanner>? onBannerTap;
  final Duration autoAdvanceInterval;
  final BorderRadius borderRadius;

  const MarketingBannerCarousel({
    super.key,
    required this.banners,
    this.onBannerTap,
    this.autoAdvanceInterval = const Duration(seconds: 3),
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
  });

  @override
  State<MarketingBannerCarousel> createState() =>
      _MarketingBannerCarouselState();
}

class _MarketingBannerCarouselState extends State<MarketingBannerCarousel> {
  late final PageController _pageController;
  Timer? _autoTimer;
  int _currentPage = 0;
  bool _userDragging = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _startAutoAdvance();
  }

  @override
  void didUpdateWidget(covariant MarketingBannerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.banners.length != widget.banners.length) {
      _currentPage = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _restartAutoAdvance();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _restartAutoAdvance() {
    _autoTimer?.cancel();
    _startAutoAdvance();
  }

  void _startAutoAdvance() {
    if (widget.banners.length <= 1) return;
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(widget.autoAdvanceInterval, (_) {
      if (!mounted || _userDragging || widget.banners.length <= 1) return;
      final next = (_currentPage + 1) % widget.banners.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.banners.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: kMarketingBannerHeight,
          width: double.infinity,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                _userDragging = true;
              } else if (notification is ScrollEndNotification) {
                _userDragging = false;
                _restartAutoAdvance();
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.banners.length,
              onPageChanged: (index) => setState(() => _currentPage = index),
              itemBuilder: (context, index) {
                final banner = widget.banners[index];
                return Padding(
                  padding: EdgeInsets.zero,
                  child: GestureDetector(
                    onTap: widget.onBannerTap == null
                        ? null
                        : () => widget.onBannerTap!(banner),
                    child: ClipRRect(
                      borderRadius: widget.borderRadius,
                      child: CachedNetworkImage(
                        imageUrl: banner.displayImageUrl,
                        cacheKey: 'banner-${banner.id}',
                        width: double.infinity,
                        height: kMarketingBannerHeight,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _BannerPlaceholder(
                          borderRadius: widget.borderRadius,
                          showProgress: true,
                        ),
                        errorWidget: (_, __, ___) => _BannerPlaceholder(
                          borderRadius: widget.borderRadius,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (widget.banners.length > 1) ...[
          const SizedBox(height: 10),
          _PageDots(
            count: widget.banners.length,
            index: _currentPage,
          ),
        ],
      ],
    );
  }
}

class _BannerPlaceholder extends StatelessWidget {
  final BorderRadius borderRadius;
  final bool showProgress;

  const _BannerPlaceholder({
    required this.borderRadius,
    this.showProgress = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: kMarketingBannerHeight,
      decoration: BoxDecoration(
        color: const Color(0xFFF0EBE3),
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: showProgress
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF1A1A1A54),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _PageDots extends StatelessWidget {
  final int count;
  final int index;

  const _PageDots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF1A1A1A)
                : const Color(0xFF1A1A1A).withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}
