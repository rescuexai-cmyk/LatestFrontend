import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Six-digit OTP entry with iOS/Android SMS one-time-code autofill support.
///
/// Uses a single hidden field (required for [AutofillHints.oneTimeCode]) and
/// renders digit boxes for display. Without this, iOS autofill only fills the
/// first box because per-box [maxLength] is 1.
class OtpInputField extends StatefulWidget {
  const OtpInputField({
    super.key,
    this.length = 6,
    this.enabled = true,
    this.controller,
    this.focusNode,
    this.boxWidth,
    this.boxHeight = 56,
    this.gap = 6,
    this.alignment = MainAxisAlignment.spaceBetween,
    this.onChanged,
    this.onCompleted,
  });

  final int length;
  final bool enabled;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final double? boxWidth;
  final double boxHeight;
  final double gap;
  final MainAxisAlignment alignment;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onCompleted;

  @override
  State<OtpInputField> createState() => _OtpInputFieldState();
}

class _OtpInputFieldState extends State<OtpInputField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final bool _ownsController;
  late final bool _ownsFocusNode;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _ownsFocusNode = widget.focusNode == null;
    _controller = widget.controller ?? TextEditingController();
    _focusNode = widget.focusNode ?? FocusNode();
    _controller.addListener(_handleControllerChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    if (_ownsController) _controller.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (mounted) setState(() {});
  }

  void _focusBox(int index) {
    if (!widget.enabled) return;
    _focusNode.requestFocus();
    final code = _controller.text;
    final offset = index.clamp(0, code.length);
    _controller.selection = TextSelection.collapsed(offset: offset);
    setState(() {});
  }

  int _focusedBoxIndex(String code) {
    if (!_focusNode.hasFocus) return -1;
    final sel = _controller.selection;
    if (!sel.isValid || !sel.isCollapsed) {
      return code.length.clamp(0, widget.length - 1);
    }
    final offset = sel.baseOffset.clamp(0, code.length);
    // Cursor at end with room left → highlight the next empty box.
    if (offset == code.length && code.length < widget.length) {
      return code.length;
    }
    return offset.clamp(0, widget.length - 1);
  }

  void _handleControllerChanged() {
    final raw = _controller.text.replaceAll(RegExp(r'\D'), '');
    if (raw != _controller.text) {
      _controller.value = TextEditingValue(
        text: raw,
        selection: TextSelection.collapsed(offset: raw.length),
      );
      return;
    }

    widget.onChanged?.call(raw);
    if (raw.length == widget.length) {
      widget.onCompleted?.call(raw);
    }
    setState(() {});
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }

    final text = _controller.text;
    if (text.isEmpty) return KeyEventResult.handled;

    final sel = _controller.selection;
    final deleteIndex = sel.isCollapsed
        ? (sel.baseOffset > 0 ? sel.baseOffset - 1 : text.length - 1)
        : sel.start - 1;

    if (deleteIndex < 0 || deleteIndex >= text.length) {
      return KeyEventResult.handled;
    }

    final newText =
        text.substring(0, deleteIndex) + text.substring(deleteIndex + 1);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: deleteIndex),
    );
    return KeyEventResult.handled;
  }

  TextEditingValue _formatOtpInput(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final clipped = digits.length > widget.length
        ? digits.substring(0, widget.length)
        : digits;

    if (clipped.length < oldValue.text.length) {
      // Backspace — move caret to the box before the deleted digit.
      return TextEditingValue(
        text: clipped,
        selection: TextSelection.collapsed(offset: clipped.length),
      );
    }

    return TextEditingValue(
      text: clipped,
      selection: TextSelection.collapsed(offset: clipped.length),
    );
  }

  Widget _buildDigitBox(int index, String text, bool isFocused) {
    final box = Container(
      height: widget.boxHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isFocused ? const Color(0xFF1A1A1A) : Colors.transparent,
          width: 2,
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1A1A1A),
        ),
      ),
    );

    if (widget.boxWidth != null) {
      return SizedBox(width: widget.boxWidth, child: box);
    }
    return Expanded(child: box);
  }

  @override
  Widget build(BuildContext context) {
    final code = _controller.text;
    final focusedIndex = _focusedBoxIndex(code);

    return AutofillGroup(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Hidden field receives full OTP from iOS QuickType / SMS autofill.
          // IgnorePointer so taps hit digit boxes below for precise caret placement.
          IgnorePointer(
            child: Opacity(
              opacity: 0.01,
              child: SizedBox(
                height: widget.boxHeight,
                width: double.infinity,
                child: Focus(
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled: widget.enabled,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    maxLength: widget.length,
                    enableSuggestions: false,
                    autocorrect: false,
                    showCursor: false,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 1, height: 1),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(widget.length),
                      TextInputFormatter.withFunction(_formatOtpInput),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: widget.alignment,
            children: [
              for (var i = 0; i < widget.length; i++) ...[
                if (i > 0) SizedBox(width: widget.gap),
                GestureDetector(
                  onTap: () => _focusBox(i),
                  behavior: HitTestBehavior.opaque,
                  child: _buildDigitBox(
                    i,
                    i < code.length ? code[i] : '',
                    widget.enabled && focusedIndex == i,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
