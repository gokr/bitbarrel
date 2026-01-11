// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:bitbarrel_admin/app.dart';
import 'package:bitbarrel_admin/di.dart';

void main() {
  setUp(() {
    // Set up dependency injection for tests
    setupDependencies();
  });

  testWidgets('BitBarrelAdminApp renders correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(BitBarrelAdminApp());

    // Verify that the app renders without errors
    expect(find.byType(BitBarrelAdminApp), findsOneWidget);

    // Pump another frame to ensure the router is initialized
    await tester.pumpAndSettle();

    // Verify that the connection screen is shown (initial route)
    expect(find.text('BitBarrel'), findsOneWidget);
    expect(find.text('Admin Console'), findsOneWidget);
  });
}
