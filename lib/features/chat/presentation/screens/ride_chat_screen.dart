import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/ride_chat_widget.dart';
import '../../providers/chat_provider.dart';

class RideChatScreen extends ConsumerWidget {
  final String rideId;
  final String currentUserId;
  final String? passengerId;
  final String otherUserName;
  final String? otherUserPhoto;
  final String? otherUserPhone;
  final bool isDriver;

  const RideChatScreen({
    super.key,
    required this.rideId,
    required this.currentUserId,
    this.passengerId,
    required this.otherUserName,
    this.otherUserPhoto,
    this.otherUserPhone,
    this.isDriver = false,
  });

  // Warm coral/orange color matching app design
  static const Color _primaryColor = Color(0xFFD4A574);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white,
              backgroundImage: otherUserPhoto != null
                  ? NetworkImage(otherUserPhoto!)
                  : null,
              child: otherUserPhoto == null
                  ? Icon(
                      isDriver ? Icons.person : Icons.drive_eta,
                      color: _primaryColor,
                      size: 20,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    otherUserName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    isDriver ? 'Passenger' : 'Driver',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (otherUserPhone != null)
            IconButton(
              icon: const Icon(Icons.phone),
              onPressed: () => _callUser(context),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildQuickActions(ref),
            Expanded(
              child: RideChatWidget(
                rideId: rideId,
                currentUserId: currentUserId,
                passengerId: passengerId,
                otherUserName: otherUserName,
                otherUserPhoto: otherUserPhoto,
                isDriver: isDriver,
                showHeader: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions(WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(
          bottom: BorderSide(color: Colors.grey[200]!),
        ),
      ),
      child: QuickChatActions(
        isDriver: isDriver,
        onQuickMessage: (message) {
          ref.read(chatProvider(rideId).notifier).sendMessage(message);
        },
      ),
    );
  }

  void _callUser(BuildContext context) {
    // You can integrate url_launcher here to make calls
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Calling $otherUserName...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// Bottom sheet version of chat for use in ride screens
class RideChatBottomSheet extends ConsumerStatefulWidget {
  final String rideId;
  final String currentUserId;
  final String? passengerId;
  final String otherUserName;
  final String? otherUserPhoto;
  final bool isDriver;

  const RideChatBottomSheet({
    super.key,
    required this.rideId,
    required this.currentUserId,
    this.passengerId,
    required this.otherUserName,
    this.otherUserPhoto,
    this.isDriver = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String rideId,
    required String currentUserId,
    String? passengerId,
    required String otherUserName,
    String? otherUserPhoto,
    bool isDriver = false,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => RideChatBottomSheet(
          rideId: rideId,
          currentUserId: currentUserId,
          passengerId: passengerId,
          otherUserName: otherUserName,
          otherUserPhoto: otherUserPhoto,
          isDriver: isDriver,
        ),
      ),
    );
  }

  @override
  ConsumerState<RideChatBottomSheet> createState() => _RideChatBottomSheetState();
}

class _RideChatBottomSheetState extends ConsumerState<RideChatBottomSheet> {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHandle(),
          _buildQuickActions(),
          Expanded(
            child: RideChatWidget(
              rideId: widget.rideId,
              currentUserId: widget.currentUserId,
              passengerId: widget.passengerId,
              otherUserName: widget.otherUserName,
              otherUserPhoto: widget.otherUserPhoto,
              isDriver: widget.isDriver,
              showHeader: true,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHandle() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.grey[300],
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildQuickActions() {
    return QuickChatActions(
      isDriver: widget.isDriver,
      onQuickMessage: (message) {
        ref.read(chatProvider(widget.rideId).notifier).sendMessage(message);
      },
    );
  }
}
