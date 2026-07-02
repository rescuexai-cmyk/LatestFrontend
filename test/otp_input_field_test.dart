import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_flutter/core/widgets/otp_input_field.dart';

void main() {
  testWidgets('OtpInputField lays out inside scrollable login sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                OtpInputField(
                  gap: 6,
                  alignment: MainAxisAlignment.start,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(OtpInputField), findsOneWidget);
  });
}
