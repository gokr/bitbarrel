import 'package:flutter/material.dart';
import 'di.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up dependency injection
  setupDependencies();

  runApp(BitBarrelAdminApp());
}
