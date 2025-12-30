import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_it/watch_it.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/services/data_service.dart';
import 'package:bitbarrel_admin/models/key_value_item.dart';
import 'package:bitbarrel_admin/widgets/json_viewer.dart';
import 'package:bitbarrel_admin/widgets/key_value_editor.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Screen for exploring key-value data in a barrel
class BarrelExplorerScreen extends StatefulWidget with WatchItStatefulWidgetMixin {
  const BarrelExplorerScreen({super.key});

  @override
  State<BarrelExplorerScreen> createState() => _BarrelExplorerScreenState();
}

class _BarrelExplorerScreenState extends State<BarrelExplorerScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedKey;
  String? _selectedValue;
  bool _isLoadingValue = false;

  @override
  void initState() {
    super.initState();
    // Load data when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final barrel = di<BarrelService>().currentBarrel.value;
      if (barrel != null) {
        di<DataService>().loadKeys();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _onSearch(String query) async {
    await di<DataService>().searchKeys(query);
  }

  Future<void> _onSelectItem(KeyValueItem item) async {
    setState(() {
      _selectedKey = item.key;
      _selectedValue = item.value;
      _isLoadingValue = false;
    });
  }

  Future<void> _onRefreshValue() async {
    if (_selectedKey == null) return;

    setState(() => _isLoadingValue = true);
    try {
      final value = await di<DataService>().getValue(_selectedKey!);
      setState(() {
        _selectedValue = value;
        _isLoadingValue = false;
      });
    } catch (e) {
      setState(() => _isLoadingValue = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load value: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _onAddKey() async {
    final result = await KeyValueEditorDialog.show(context);
    if (result == null) return;

    final (key, value) = result;
    try {
      await di<DataService>().setValue(key, value);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added key: $key'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add key: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _onEditKey(String key, String value) async {
    final result = await KeyValueEditorDialog.show(
      context,
      initialKey: key,
      initialValue: value,
      isEditing: true,
    );
    if (result == null) return;

    final (_, newValue) = result;
    try {
      await di<DataService>().setValue(key, newValue);
      if (_selectedKey == key) {
        setState(() => _selectedValue = newValue);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Updated key: $key'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update key: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _onDeleteKey(String key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Are you sure you want to delete "$key"?\n\nThis action cannot be undone.'),
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

    if (confirmed != true) return;

    try {
      await di<DataService>().deleteKey(key);
      if (_selectedKey == key) {
        setState(() {
          _selectedKey = null;
          _selectedValue = null;
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted key: $key'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete key: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final barrel = watchValue((BarrelService s) => s.currentBarrel);
    final items = watchValue((DataService s) => s.items);
    final isLoading = watchValue((DataService s) => s.isLoading);
    final error = watchValue((DataService s) => s.error);
    final hasMore = watchValue((DataService s) => s.hasMore);
    final totalCount = watchValue((DataService s) => s.totalCount);
    final searchQuery = watchValue((DataService s) => s.searchQuery);

    // If no barrel is selected, redirect to dashboard
    if (barrel == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Data Explorer'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/dashboard'),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.storage,
                size: 64,
                color: AppTheme.secondaryColor.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No barrel selected',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.secondaryColor.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => context.go('/dashboard'),
                style: AppTheme.primaryButtonStyle,
                child: const Text('Go to Dashboard'),
              ),
            ],
          ),
        ),
      );
    }

    final supportsRangeQueries = barrel.supportsRangeQueries;

    return Scaffold(
      appBar: AppBar(
        title: Text('Explorer: ${barrel.name}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Query Interface',
            onPressed: supportsRangeQueries ? () => context.go('/query') : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isLoading ? null : () => di<DataService>().loadKeys(),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Header with stats and search
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.cardColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Stats row
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$totalCount keys',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (barrel.indexMode != null)
                            Text(
                              'Index: ${barrel.indexMode}${supportsRangeQueries ? ' (range queries supported)' : ''}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: supportsRangeQueries
                                    ? AppTheme.successColor
                                    : AppTheme.secondaryColor,
                              ),
                            ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _onAddKey,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Key'),
                      style: AppTheme.primaryButtonStyle,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Search bar
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: supportsRangeQueries
                        ? 'Search by prefix...'
                        : 'Filter keys...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _onSearch('');
                            },
                          )
                        : null,
                  ),
                  onChanged: _onSearch,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Error message
          if (error != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: AppTheme.errorColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error,
                      style: TextStyle(color: AppTheme.errorColor),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: AppTheme.errorColor),
                    onPressed: () => di<DataService>().error.value = null,
                  ),
                ],
              ),
            ),
          ],

          // Loading indicator
          if (isLoading)
            const LinearProgressIndicator(),

          // Main content - split view
          Expanded(
            child: Row(
              children: [
                // Left panel - key list
                SizedBox(
                  width: 400,
                  child: _buildKeyList(items, hasMore, isLoading, searchQuery),
                ),
                const VerticalDivider(width: 1),

                // Right panel - value detail
                Expanded(
                  child: _buildValuePanel(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyList(List<KeyValueItem> items, bool hasMore, bool isLoading, String searchQuery) {
    if (items.isEmpty && !isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox,
              size: 48,
              color: AppTheme.secondaryColor.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              searchQuery.isNotEmpty
                  ? 'No matching keys'
                  : 'No keys in this barrel',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.secondaryColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          // Load more button
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ElevatedButton(
                onPressed: isLoading ? null : () => di<DataService>().loadNextPage(),
                child: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Load More'),
              ),
            ),
          );
        }

        final item = items[index];
        final isSelected = item.key == _selectedKey;

        return Container(
          color: isSelected ? AppTheme.accentColor.withValues(alpha: 0.1) : null,
          child: ListTile(
            leading: Icon(
              item.isJson ? Icons.data_object : Icons.text_snippet,
              color: item.isJson ? AppTheme.accentColor : AppTheme.secondaryColor,
              size: 20,
            ),
            title: Text(
              item.key,
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              item.valuePreview,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppTheme.secondaryColor.withValues(alpha: 0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Edit',
                  onPressed: () => _onEditKey(item.key, item.value),
                ),
                IconButton(
                  icon: Icon(Icons.delete, size: 18, color: AppTheme.errorColor),
                  tooltip: 'Delete',
                  onPressed: () => _onDeleteKey(item.key),
                ),
              ],
            ),
            onTap: () => _onSelectItem(item),
            selected: isSelected,
          ),
        );
      },
    );
  }

  Widget _buildValuePanel() {
    if (_selectedKey == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.touch_app,
              size: 48,
              color: AppTheme.secondaryColor.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Select a key to view its value',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.secondaryColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with key name and actions
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.cardColor,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Key',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                    SelectableText(
                      _selectedKey!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh value',
                onPressed: _isLoadingValue ? null : _onRefreshValue,
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Edit',
                onPressed: _selectedValue != null
                    ? () => _onEditKey(_selectedKey!, _selectedValue!)
                    : null,
              ),
              IconButton(
                icon: Icon(Icons.delete, color: AppTheme.errorColor),
                tooltip: 'Delete',
                onPressed: () => _onDeleteKey(_selectedKey!),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Value content
        Expanded(
          child: _isLoadingValue
              ? const Center(child: CircularProgressIndicator())
              : Container(
                  padding: const EdgeInsets.all(16),
                  child: _selectedValue != null
                      ? JsonViewer(data: _selectedValue!)
                      : const Text('(no value)'),
                ),
        ),
      ],
    );
  }
}
