import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/models/chat_message.dart';
import '../../providers/chat_provider.dart';

class RideChatWidget extends ConsumerStatefulWidget {
  final String rideId;
  final String currentUserId;
  final String? passengerId;
  final String otherUserName;
  final String? otherUserPhoto;
  final bool isDriver;
  final VoidCallback? onClose;
  final bool showHeader;
  final Color? primaryColor;

  const RideChatWidget({
    super.key,
    required this.rideId,
    required this.currentUserId,
    this.passengerId,
    required this.otherUserName,
    this.otherUserPhoto,
    this.isDriver = false,
    this.onClose,
    this.showHeader = true,
    this.primaryColor,
  });

  @override
  ConsumerState<RideChatWidget> createState() => _RideChatWidgetState();
}

class _RideChatWidgetState extends ConsumerState<RideChatWidget> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  Timer? _typingDebounce;
  bool _isInitialized = false;

  // Warm coral/orange color matching passenger app design
  Color get _primaryColor => widget.primaryColor ?? const Color(0xFFD4A574);

  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  void _initializeChat() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isInitialized) {
        final notifier = ref.read(chatProvider(widget.rideId).notifier);
        notifier.initialize(
          currentUserId: widget.currentUserId,
          passengerId: widget.passengerId,
          isDriver: widget.isDriver,
        );
        notifier.openChat();
        _isInitialized = true;
      }
    });
  }

  @override
  void dispose() {
    ref.read(chatProvider(widget.rideId).notifier).sendTypingStop();
    ref.read(chatProvider(widget.rideId).notifier).closeChat();
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _typingDebounce?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.minScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _onTextChanged(String text) {
    _typingDebounce?.cancel();
    final notifier = ref.read(chatProvider(widget.rideId).notifier);
    if (text.trim().isEmpty) {
      notifier.sendTypingStop();
      return;
    }
    notifier.sendTypingStart();
    _typingDebounce = Timer(const Duration(milliseconds: 900), () {
      notifier.sendTypingStop();
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    ref.read(chatProvider(widget.rideId).notifier).sendTypingStop();
    _focusNode.requestFocus();

    final success = await ref.read(chatProvider(widget.rideId).notifier).sendMessage(text);
    
    if (success) {
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider(widget.rideId));

    ref.listen<ChatState>(chatProvider(widget.rideId), (prev, next) {
      if (prev?.messages.length != next.messages.length) {
        _scrollToBottom();
      }
    });

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (widget.showHeader) _buildHeader(),
          if (widget.showHeader) const SizedBox(height: 5),
          Expanded(
            child: chatState.isLoading && chatState.messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : chatState.messages.isEmpty
                    ? _buildEmptyState()
                    : _buildMessageList(chatState),
          ),
          if (chatState.otherUserTyping) _buildTypingIndicator(),
          _buildInputArea(chatState),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final otherTyping = ref.watch(
      chatProvider(widget.rideId).select((s) => s.otherUserTyping),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _primaryColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white,
            backgroundImage: widget.otherUserPhoto != null
                ? NetworkImage(widget.otherUserPhoto!)
                : null,
            child: widget.otherUserPhoto == null
                ? Icon(
                    widget.isDriver ? Icons.person : Icons.drive_eta,
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
                  widget.otherUserName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  otherTyping
                      ? '${widget.otherUserName} is typing...'
                      : (widget.isDriver ? 'Passenger' : 'Driver'),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                    fontStyle: otherTyping ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onClose != null)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Send a message to ${widget.otherUserName}',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(ChatState chatState) {
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: chatState.messages.length,
      itemBuilder: (context, index) {
        final reverseIndex = chatState.messages.length - 1 - index;
        final message = chatState.messages[reverseIndex];
        final prevIndex = reverseIndex + 1;
        final showDate = reverseIndex == 0 ||
            (prevIndex < chatState.messages.length &&
                !_isSameDay(
                  chatState.messages[prevIndex].timestamp,
                  message.timestamp,
                ));

        return Column(
          children: [
            if (showDate) _buildDateDivider(message.timestamp),
            _buildMessageBubble(message),
          ],
        );
      },
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Widget _buildDateDivider(DateTime date) {
    final now = DateTime.now();
    String text;
    
    if (_isSameDay(date, now)) {
      text = 'Today';
    } else if (_isSameDay(date, now.subtract(const Duration(days: 1)))) {
      text = 'Yesterday';
    } else {
      text = DateFormat('MMM d, yyyy').format(date);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: Colors.grey[300])),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Divider(color: Colors.grey[300])),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    // Check if message is from current user by comparing senderId
    final isMe = message.senderId == widget.currentUserId ||
        (widget.isDriver && message.senderType == ChatSenderType.driver) ||
        (!widget.isDriver && message.senderType == ChatSenderType.passenger);
    
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? _primaryColor : Colors.grey[100],
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message.message,
              style: TextStyle(
                color: isMe ? Colors.white : Colors.black87,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('hh:mm a').format(message.timestamp.toLocal()),
                  style: TextStyle(
                    color: isMe ? Colors.white70 : Colors.grey[500],
                    fontSize: 11,
                  ),
                ),
                if (isMe && message.isSending) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ),
                ],
                if (isMe && message.sendFailed) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () {
                      ref.read(chatProvider(widget.rideId).notifier)
                          .retryMessage(message.id);
                    },
                    child: const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 16,
                    ),
                  ),
                ],
                if (isMe && !message.isSending && !message.sendFailed) ...[
                  const SizedBox(width: 4),
                  _buildStatusTicks(message),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusTicks(ChatMessage message) {
    switch (message.status) {
      case MessageDeliveryStatus.queued:
        return const Icon(Icons.schedule, color: Colors.white70, size: 14);
      case MessageDeliveryStatus.sent:
        return const Icon(Icons.done, color: Colors.white70, size: 14);
      case MessageDeliveryStatus.delivered:
        return const Icon(Icons.done_all, color: Colors.white70, size: 14);
      case MessageDeliveryStatus.read:
        return const Icon(Icons.done_all, color: Colors.lightBlueAccent, size: 14);
      case MessageDeliveryStatus.failed:
        return const Icon(Icons.error_outline, color: Colors.redAccent, size: 14);
    }
  }

  Widget _buildTypingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTypingDot(0),
                const SizedBox(width: 4),
                _buildTypingDot(1),
                const SizedBox(width: 4),
                _buildTypingDot(2),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${widget.otherUserName} is typing...',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 600 + (index * 200)),
      builder: (context, value, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.grey[400]!.withOpacity(0.5 + (0.5 * value)),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }

  Widget _buildInputArea(ChatState chatState) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.grey[200]!),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _messageController,
                focusNode: _focusNode,
                onChanged: _onTextChanged,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: TextStyle(color: Colors.grey[500]),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: _primaryColor,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: chatState.isSending ? null : _sendMessage,
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: chatState.isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick action buttons for common messages (like Uber)
class QuickChatActions extends StatelessWidget {
  final Function(String) onQuickMessage;
  final bool isDriver;

  const QuickChatActions({
    super.key,
    required this.onQuickMessage,
    this.isDriver = false,
  });

  @override
  Widget build(BuildContext context) {
    final messages = isDriver
        ? [
            'On my way!',
            'I\'m here',
            'Running 5 min late',
            'Can\'t find you',
          ]
        : [
            'I\'m coming out',
            'Please wait',
            'Where are you?',
            'I\'m at the pickup',
          ];

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: messages.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return ActionChip(
            label: Text(
              messages[index],
              style: const TextStyle(fontSize: 13),
            ),
            backgroundColor: Colors.grey[100],
            onPressed: () => onQuickMessage(messages[index]),
          );
        },
      ),
    );
  }
}
