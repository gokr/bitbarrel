import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_it/watch_it.dart';
import 'package:bitbarrel/bitbarrel.dart';
import 'package:bitbarrel_admin/services/data_service.dart';
import 'package:bitbarrel_admin/widgets/graph_visualizer.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Graph traversal screen for exploring relationships between keys
class TraversalScreen extends StatefulWidget with WatchItStatefulWidgetMixin {
  const TraversalScreen({super.key});

  @override
  State<TraversalScreen> createState() => _TraversalScreenState();
}

class _TraversalScreenState extends State<TraversalScreen> {
  // Query inputs
  final TextEditingController _startKeyController = TextEditingController();
  final TextEditingController _pathSpecController = TextEditingController();

  // Options
  bool _includeFullData = true;
  bool _firstOnly = false;

  // Results
  List<TraverseResult> _results = [];
  bool _isLoading = false;
  String? _error;

  // Selected result
  TraverseResult? _selectedResult;

  @override
  void dispose() {
    _startKeyController.dispose();
    _pathSpecController.dispose();
    super.dispose();
  }

  Future<void> _executeTraversal() async {
    final startKey = _startKeyController.text.trim();
    final pathSpec = _pathSpecController.text.trim();

    if (startKey.isEmpty) {
      setState(() => _error = 'Starting key is required');
      return;
    }

    if (pathSpec.isEmpty) {
      setState(() => _error = 'Path spec is required');
      return;
    }

    final dataService = di<DataService>();

    setState(() {
      _isLoading = true;
      _error = null;
      _results = [];
      _selectedResult = null;
    });

    try {
      final results = await dataService.traverse(
        startKey,
        pathSpec,
        includeFullData: _includeFullData,
        firstOnly: _firstOnly,
      );

      setState(() {
        _results = results;
        _isLoading = false;
      });

      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No results found for the given path'),
            backgroundColor: AppTheme.secondaryColor,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Traversal failed: $e';
        _isLoading = false;
      });
    }
  }

  void _onSelectResult(TraverseResult result) {
    setState(() {
      if (_selectedResult?.key == result.key && _selectedResult?.path == result.path) {
        _selectedResult = null;
      } else {
        _selectedResult = result;
      }
    });
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Graph Traversal Help'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Graph traversal follows _ref relationships between keys.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                'Starting Key',
                'The key to begin traversal from. This key should contain _ref fields.',
              ),
              _buildHelpSection(
                'Path Specification',
                'Syntax for specifying which relationships to follow:\n'
                '- Specific relation: friends - follow "friends" ref\n'
                '- Chained: friends->team - follow "friends", then "team" from those\n'
                '- Wildcard: * - follow all ref types\n'
                '- Array slice: [0:5] - only the first 5 items\n'
                '- Combined: *->posts[0:10] - all relations, then "posts" limited to 10',
              ),
              _buildHelpSection(
                'Options',
                '- Include Data: Include full values in results\n'
                '- First Only: Return only the first match (faster)',
              ),
              const SizedBox(height: 16),
              const Text('Example Data with _ref:'),
              const SizedBox(height: 4),
              const SelectableText(
'''{
  "name": "John",
  "_ref": {
    "friends": ["user:2", "user:3"],
    "team": "team:1"
  }
}''',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  backgroundColor: AppTheme.cardColor,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpSection(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(content),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph Traversal'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/explorer'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelpDialog,
            tooltip: 'How to use',
          ),
        ],
      ),
      body: Column(
        children: [
          // Query form
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.cardColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _startKeyController,
                  decoration: const InputDecoration(
                    labelText: 'Starting Key',
                    hintText: 'e.g., user:12345',
                    prefixIcon: Icon(Icons.play_arrow),
                  ),
                  onSubmitted: (_) => _executeTraversal(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pathSpecController,
                  decoration: const InputDecoration(
                    labelText: 'Path Specification',
                    hintText: 'e.g., friends->team or *->posts[0:10]',
                    prefixIcon: Icon(Icons.account_tree),
                  ),
                  onSubmitted: (_) => _executeTraversal(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Tooltip(
                      message: 'Include full value data in results',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _includeFullData,
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _includeFullData = v);
                              }
                            },
                          ),
                          const Text('Include Data'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Tooltip(
                      message: 'Return only the first matching result',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _firstOnly,
                            onChanged: (v) {
                              if (v != null) {
                                setState(() => _firstOnly = v);
                              }
                            },
                          ),
                          const Text('First Only'),
                        ],
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _executeTraversal,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: const Text('Traverse'),
                      style: AppTheme.primaryButtonStyle,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Error message
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(16),
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppTheme.errorColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: AppTheme.errorColor),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.errorColor),
                    onPressed: () => setState(() => _error = null),
                  ),
                ],
              ),
            ),

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
                  child: GraphVisualizer(
                    results: _results,
                    onSelect: _onSelectResult,
                    selected: _selectedResult,
                  ),
                ),
                const VerticalDivider(width: 1),

                // Right panel - value detail
                Expanded(
                  child: GraphResultPanel(result: _selectedResult),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}