import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_it/watch_it.dart';
import '../services/connection_service.dart';
import '../theme/app_theme.dart';

/// Connection screen for connecting to BitBarrel server
class ConnectionScreen extends StatelessWidget with WatchItMixin {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController(text: 'localhost');
  final _portController = TextEditingController(text: '9876');

  void _disposeControllers() {
    _hostController.dispose();
    _portController.dispose();
  }

  Future<void> _connect(BuildContext context) async {
    if (_formKey.currentState!.validate()) {
      final host = _hostController.text;
      final port = int.parse(_portController.text);

      try {
        await di<ConnectionService>().connect(host, port);

        if (di<ConnectionService>().connected) {
          // Navigate to dashboard
          context.go('/dashboard');
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to connect: $e'),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = watchValue((ConnectionService s) => s.isConnected);
    final isConnecting = watchValue((ConnectionService s) => s.isConnecting);
    final error = watchValue((ConnectionService s) => s.error);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.backgroundColor,
              Colors.white,
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Logo/Title
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.accentColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                IconData(0xe2ca, fontFamily: 'MaterialIcons'), // Database icon
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              'BitBarrel',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: AppTheme.primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Admin Console',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.secondaryColor,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),

                        // Host input
                        TextFormField(
                          controller: _hostController,
                          decoration: AppTheme.inputDecoration(
                            label: 'Host',
                            hint: 'localhost',
                            prefixIcon: const Icon(Icons.computer),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter a host';
                            }
                            return null;
                          },
                          enabled: !isConnecting,
                        ),
                        const SizedBox(height: 16),

                        // Port input
                        TextFormField(
                          controller: _portController,
                          decoration: AppTheme.inputDecoration(
                            label: 'Port',
                            hint: '9876',
                            prefixIcon: const Icon(Icons.numbers),
                          ),
                          keyboardType: TextInputType.number,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter a port';
                            }
                            final port = int.tryParse(value);
                            if (port == null || port < 1 || port > 65535) {
                              return 'Please enter a valid port (1-65535)';
                            }
                            return null;
                          },
                          enabled: !isConnecting,
                        ),
                        const SizedBox(height: 24),

                        // Error message
                        if (error != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.errorColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppTheme.errorColor.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: AppTheme.errorColor,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    error!,
                                    style: TextStyle(
                                      color: AppTheme.errorColor,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Connect button
                        ElevatedButton(
                          onPressed: (isConnecting) ? null : () => _connect(context),
                          style: AppTheme.primaryButtonStyle.copyWith(
                            padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                          child: isConnecting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                              : const Text(
                                  'Connect',
                                  style: TextStyle(fontSize: 16),
                                ),
                        ),
                        const SizedBox(height: 24),

                        // Status indicator
                        if (isConnected) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: AppTheme.successColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppTheme.successColor.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check_circle,
                                  color: AppTheme.successColor,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Connected',
                                  style: TextStyle(
                                    color: AppTheme.successColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
