import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_it/watch_it.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/services/data_service.dart';
import 'package:bitbarrel_admin/models/key_value_item.dart';
import 'package:bitbarrel_admin/widgets/json_viewer.dart';
import 'package:bitbarrel_admin/widgets/key_value_editor.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Query interface screen for prefix and range queries
class QueryScreen extends StatefulWidget with WatchItStatefulWidgetMixin {
  const QueryScreen({super.key});

  @override
  State<QueryScreen> createState() => _QueryScreenState();
}

class _QueryScreenState extends State<QueryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Query inputs
  final TextEditingController _prefixController = TextEditingController();
  final TextEditingController _startKeyController = TextEditingController();
  final TextEditingController _endKeyController = TextEditingController();
  final TextEditingController _limitController = TextEditingController(text: '100');

  // Results
  List<KeyValueItem> _results = [];
  String _nextCursor = '';
  bool _hasMore = false;
  bool _isLoading = false;
  String? _error;

  // Selected item
  String? _selectedKey;
  String? _selectedValue;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _prefixController.dispose();
    _startKeyController.dispose();
    _endKeyController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  int get _limit {
    final val = int.tryParse(_limitController.text);
    return val != null && val > 0 ? val : 100;
  }

  Future<void> _executePrefixQuery({bool loadMore = false}) async {
    final dataService = di<DataService>();
    if (!dataService.supportsRangeQueries) {
      setState(() => _error = 'Range queries not supported in Hash mode');
      return;
    }

    final prefix = _prefixController.text;
    final cursor = loadMore ? _nextCursor : '';

    setState(() {
      _isLoading = true;
      _error = null;
      if (!loadMore) {
        _results = [];
        _selectedKey = null;
        _selectedValue = null;
      }
    });

    try {
      final response = await dataService.prefixQuery(
        prefix,
        limit: _limit,
        cursor: cursor,
      );

      final newItems = response.items
          .map((kv) => KeyValueItem(key: kv.key, value: kv.value))
          .toList();

      setState(() {
        if (loadMore) {
          _results = [..._results, ...newItems];
        } else {
          _results = newItems;
        }
        _nextCursor = response.nextCursor;
        _hasMore = response.hasMore;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Query failed: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _executeRangeQuery({bool loadMore = false}) async {
    final dataService = di<DataService>();
    if (!dataService.supportsRangeQueries) {
      setState(() => _error = 'Range queries not supported in Hash mode');
      return;
    }

    final startKey = _startKeyController.text;
    final endKey = _endKeyController.text;

    if (startKey.isEmpty || endKey.isEmpty) {
      setState(() => _error = 'Start and end keys are required');
      return;
    }

    final cursor = loadMore ? _nextCursor : '';

    setState(() {
      _isLoading = true;
      _error = null;
      if (!loadMore) {
        _results = [];
        _selectedKey = null;
        _selectedValue = null;
      }
    });

    try {
      final response = await dataService.rangeQuery(
        startKey,
        endKey,
        limit: _limit,
        cursor: cursor,
      );

      final newItems = response.items
          .map((kv) => KeyValueItem(key: kv.key, value: kv.value))
          .toList();

      setState(() {
        if (loadMore) {
          _results = [..._results, ...newItems];
        } else {
          _results = newItems;
        }
        _nextCursor = response.nextCursor;
        _hasMore = response.hasMore;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Query failed: $e';
        _isLoading = false;
      });
    }
  }

  void _onSelectItem(KeyValueItem item) {
    setState(() {
      _selectedKey = item.key;
      _selectedValue = item.value;
    });
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

      // Update local result
      final idx = _results.indexWhere((item) => item.key == key);
      if (idx >= 0) {
        setState(() {
          _results[idx] = KeyValueItem(key: key, value: newValue);
          if (_selectedKey == key) {
            _selectedValue = newValue;
          }
        });
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

      setState(() {
        _results = _results.where((item) => item.key != key).toList();
        if (_selectedKey == key) {
          _selectedKey = null;
          _selectedValue = null;
        }
      });

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

    // If no barrel is selected or doesn't support range queries
    if (barrel == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Query Interface'),
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

    if (!barrel.supportsRangeQueries) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Query: ${barrel.name}'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/explorer'),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.block,
                size: 64,
                color: AppTheme.warningColor,
              ),
              const SizedBox(height: 16),
              Text(
                'Range queries not supported',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'This barrel uses Hash index mode.\nCreate a CritBit barrel to use range queries.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.secondaryColor,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => context.go('/explorer'),
                child: const Text('Back to Explorer'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Query: ${barrel.name}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/explorer'),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Prefix Query', icon: Icon(Icons.text_fields)),
            Tab(text: 'Range Query', icon: Icon(Icons.swap_horiz)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Query form - SizedBox provides bounded height for TabBarView
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.cardColor,
            child: SizedBox(
              height: 100,
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Prefix query form
                  _buildPrefixQueryForm(),
                  // Range query form
                  _buildRangeQueryForm(),
                ],
              ),
            ),
          ),
          const Divider(height: 1),

          // Error message
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: AppTheme.errorColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppTheme.errorColor),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: AppTheme.errorColor),
                    onPressed: () => setState(() => _error = null),
                  ),
                ],
              ),
            ),
          ],

          // Loading indicator
          if (_isLoading)
            const LinearProgressIndicator(),

          // Results
          Expanded(
            child: Row(
              children: [
                // Left panel - results list
                SizedBox(
                  width: 400,
                  child: _buildResultsList(),
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

  Widget _buildPrefixQueryForm() {
    return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _prefixController,
              decoration: const InputDecoration(
                labelText: 'Prefix',
                hintText: 'e.g., user:',
                prefixIcon: Icon(Icons.text_fields),
              ),
              onSubmitted: (_) => _executePrefixQuery(),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 100,
            child: TextField(
              controller: _limitController,
              decoration: const InputDecoration(
                labelText: 'Limit',
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : () => _executePrefixQuery(),
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('Search'),
              style: AppTheme.primaryButtonStyle,
            ),
          ),
        ],
    );
  }

  Widget _buildRangeQueryForm() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _startKeyController,
              decoration: const InputDecoration(
                labelText: 'Start Key',
                hintText: 'e.g., user:0001',
                prefixIcon: Icon(Icons.first_page),
              ),
              onSubmitted: (_) => _executeRangeQuery(),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _endKeyController,
              decoration: const InputDecoration(
                labelText: 'End Key',
                hintText: 'e.g., user:0100',
                prefixIcon: Icon(Icons.last_page),
              ),
              onSubmitted: (_) => _executeRangeQuery(),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 100,
            child: TextField(
              controller: _limitController,
              decoration: const InputDecoration(
                labelText: 'Limit',
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : () => _executeRangeQuery(),
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: const Text('Search'),
              style: AppTheme.primaryButtonStyle,
            ),
          ),
        ],
    );
  }

  Widget _buildResultsList() {
    if (_results.isEmpty && !_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 48,
              color: AppTheme.secondaryColor.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Execute a query to see results',
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
        // Results count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${_results.length} results${_hasMore ? ' (more available)' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.secondaryColor,
            ),
          ),
        ),

        // Results list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _results.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _results.length) {
                // Load more button
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ElevatedButton(
                      onPressed: _isLoading
                          ? null
                          : () {
                              if (_tabController.index == 0) {
                                _executePrefixQuery(loadMore: true);
                              } else {
                                _executeRangeQuery(loadMore: true);
                              }
                            },
                      child: _isLoading
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

              final item = _results[index];
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
          ),
        ),
      ],
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
              'Select a result to view its value',
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
          child: Container(
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
