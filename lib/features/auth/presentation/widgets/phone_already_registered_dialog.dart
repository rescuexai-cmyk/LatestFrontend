import 'package:flutter/material.dart';

/// True when backend/Firebase indicates the phone belongs to another account.
bool isPhoneAlreadyRegisteredError(String? message) {
  if (message == null || message.trim().isEmpty) return false;
  final m = message.toLowerCase();
  return (m.contains('already') &&
          (m.contains('use') ||
              m.contains('exist') ||
              m.contains('linked') ||
              m.contains('registered'))) ||
      m.contains('phone number is already');
}

/// Prompts the user to log in with the existing account or try another number.
Future<void> showPhoneAlreadyRegisteredDialog({
  required BuildContext context,
  required VoidCallback onLoginWithPhone,
  required VoidCallback onUseDifferentNumber,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Phone number already registered',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      content: const Text(
        'This number is linked to an existing Raahi account. Log in with this '
        'number, or go back and use a different one.',
        style: TextStyle(fontSize: 15, height: 1.4, color: Color(0xFF616161)),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            onUseDifferentNumber();
          },
          child: const Text('Use different number'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            onLoginWithPhone();
          },
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A1A),
          ),
          child: const Text('Log in with this number'),
        ),
      ],
    ),
  );
}
