import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_it/watch_it.dart';
import '../services/barrel_service.dart';
import '../services/connection_service.dart';
import '../theme/app_theme.dart';
import '../widgets/barrel_config_dialog.dart';

/// Dashboard screen showing available barrels
class DashboardScreen extends StatefulWidget with WatchItStatefulWidgetMixin {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    // Load barrels when screen opens
    di<BarrelService>().loadBarrels();
  }

  Future<void> _createBarrel(BuildContext context) async {
    final nameController = TextEditingController();
    String? selectedMode = 'hash'; // default

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create New Barrel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Barrel Name',
                hintText: 'my_database',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selectedMode,
              decoration: const InputDecoration(
                labelText: 'Index Mode',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'hash',
                  child: Text('Hash (Fast lookups)'),
                ),
                DropdownMenuItem(
                  value: 'critbit',
                  child: Text('CritBit (Range queries)'),
                ),
                DropdownMenuItem(
                  value: 'hugecritbit',
                  child: Text('HugeCritBit (Massive datasets)'),
                ),
              ],
              onChanged: (value) {
                selectedMode = value;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                Navigator.of(dialogContext).pop(true);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final config = selectedMode != null ? '{"mode":"$selectedMode"}' : null;
        await di<BarrelService>().createBarrel(nameController.text, config: config);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Barrel "${nameController.text}" created successfully'),
              backgroundColor: AppTheme.successColor,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create barrel: $e'),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      }
    }

    nameController.dispose();
  }

  Future<void> _deleteBarrel(BuildContext context, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Barrel'),
        content: Text('Are you sure you want to delete "$name"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await di<BarrelService>().deleteBarrel(name);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Barrel "$name" deleted'),
              backgroundColor: AppTheme.successColor,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete barrel: $e'),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      }
    }
  }

  Future<void> _selectBarrel(BuildContext context, String name) async {
    try {
      await di<BarrelService>().useBarrel(name);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Selected barrel: $name'),
            backgroundColor: AppTheme.successColor,
          ),
        );

        // Navigate to explorer
        context.go('/explorer');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to select barrel: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _disconnect(BuildContext context) async {
    await di<ConnectionService>().disconnect();
    if (context.mounted) {
      context.go('/');
    }
  }

  Future<void> _configureBarrel(BuildContext context, String name) async {
    final result = await BarrelConfigDialog.show(
      context,
      barrelName: name,
    );

    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Configuration updated for "$name"'),
          backgroundColor: AppTheme.successColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final barrels = watchValue((BarrelService s) => s.barrels);
    final isLoading = watchValue((BarrelService s) => s.isLoading);
    final error = watchValue((BarrelService s) => s.error);
    final isConnected = watchValue((ConnectionService s) => s.isConnected);

    // If not connected, show prompt to connect
    if (!isConnected) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('BitBarrel Dashboard'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                size: 64,
                color: AppTheme.secondaryColor.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'Not connected to server',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.secondaryColor.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => context.go('/'),
                icon: const Icon(Icons.login),
                label: const Text('Connect'),
                style: AppTheme.primaryButtonStyle,
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('BitBarrel Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isLoading ? null : () => di<BarrelService>().loadBarrels(),
            tooltip: 'Refresh barrels',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => _disconnect(context),
            tooltip: 'Disconnect',
          ),
        ],
      ),
      body: Column(
        children: [
          // Header with stats
          Container(
            padding: const EdgeInsets.all(24),
            color: AppTheme.cardColor,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BitBarrel Server',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Connected • ${barrels.length} barrels',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.successColor,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => _createBarrel(context),
                  icon: const Icon(Icons.add),
                  label: const Text('New Barrel'),
                  style: AppTheme.primaryButtonStyle,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Error message
          if (error != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.errorColor.withOpacity(0.1),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: AppTheme.errorColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      style: TextStyle(color: AppTheme.errorColor),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: AppTheme.errorColor),
                    onPressed: () => di<BarrelService>().error.value = null,
                  ),
                ],
              ),
            ),
          ],

          // Loading indicator
          if (isLoading)
            const LinearProgressIndicator(),

          // Barrel list
          Expanded(
            child: barrels.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.storage,
                          size: 64,
                          color: AppTheme.secondaryColor.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No barrels found',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.secondaryColor.withOpacity(0.7),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Create a new barrel to get started',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.secondaryColor.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: barrels.length,
                    itemBuilder: (context, index) {
                      final barrel = barrels[index];
                      return Card(
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.storage,
                              color: AppTheme.primaryColor,
                            ),
                          ),
                          title: Text(
                            barrel.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (barrel.indexMode != null)
                                Text(
                                  'Index: ${barrel.indexMode}',
                                  style: TextStyle(
                                    color: AppTheme.secondaryColor.withOpacity(0.7),
                                    fontSize: 12,
                                  ),
                                ),
                              if (barrel.supportsRangeQueries)
                                const Text(
                                  'Supports range queries',
                                  style: TextStyle(
                                    color: AppTheme.successColor,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.visibility),
                                tooltip: 'Explore',
                                onPressed: () => _selectBarrel(context, barrel.name),
                              ),
                              IconButton(
                                icon: const Icon(Icons.settings),
                                tooltip: 'Configure',
                                onPressed: () => _configureBarrel(context, barrel.name),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete, color: AppTheme.errorColor),
                                tooltip: 'Delete',
                                onPressed: () => _deleteBarrel(context, barrel.name),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
