import 'package:flutter/material.dart';
import 'package:bitbarrel/bitbarrel.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';
import 'json_viewer.dart';

/// Widget to display graph traversal results as a tree/list
class GraphVisualizer extends StatefulWidget {
  final List<TraverseResult> results;
  final Function(TraverseResult) onSelect;
  final TraverseResult? selected;

  const GraphVisualizer({
    super.key,
    required this.results,
    required this.onSelect,
    this.selected,
  });

  @override
  State<GraphVisualizer> createState() => _GraphVisualizerState();
}

class _GraphVisualizerState extends State<GraphVisualizer> {
  @override
  Widget build(BuildContext context) {
    if (widget.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_tree,
              size: 48,
              color: AppTheme.secondaryColor.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No results yet.\nEnter a starting key and path spec, then click Traverse.',
              textAlign: TextAlign.center,
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
            '${widget.results.length} result${widget.results.length != 1 ? 's' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.secondaryColor,
                ),
          ),
        ),

        // Results list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: widget.results.length,
            itemBuilder: (context, index) {
              final result = widget.results[index];
              final isSelected = widget.selected?.key == result.key;

              return _buildResultItem(context, result, isSelected);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultItem(BuildContext context, TraverseResult result, bool isSelected) {
    final hasJsonValue = _isJson(result.value);
    final pathParts = result.path.split('->');

    return Container(
      color: isSelected ? AppTheme.accentColor.withValues(alpha: 0.1) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Path indicator
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(
                  Icons.subdirectory_arrow_right,
                  size: 14,
                  color: AppTheme.secondaryColor.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    result.path,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppTheme.secondaryColor.withValues(alpha: 0.7),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // Key and value preview
          ListTile(
            leading: Icon(
              hasJsonValue ? Icons.data_object : Icons.text_snippet,
              color: hasJsonValue ? AppTheme.accentColor : AppTheme.secondaryColor,
              size: 20,
            ),
            title: Text(
              result.key,
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _getValuePreview(result.value),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppTheme.secondaryColor.withValues(alpha: 0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              isSelected ? Icons.arrow_forward : null,
              color: AppTheme.accentColor,
            ),
            onTap: () => widget.onSelect(result),
            selected: isSelected,
          ),
        ],
      ),
    );
  }

  bool _isJson(String value) {
    if (value.isEmpty) return false;
    final trimmed = value.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
           (trimmed.startsWith('[') && trimmed.endsWith(']'));
  }

  String _getValuePreview(String value) {
    if (value.isEmpty) return '(empty)';

    // If it's JSON, show a short preview
    if (_isJson(value)) {
      final preview = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (preview.length > 50) {
        return '${preview.substring(0, 47)}...';
      }
      return preview;
    }

    // For plain text, truncate
    if (value.length > 50) {
      return '${value.substring(0, 47)}...';
    }
    return value;
  }
}

/// Panel to display the selected traversal result's full value
class GraphResultPanel extends StatelessWidget {
  final TraverseResult? result;

  const GraphResultPanel({super.key, this.result});

  @override
  Widget build(BuildContext context) {
    if (result == null) {
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

    final isJson = _isJson(result!.value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with path
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.cardColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Path:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.secondaryColor,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result!.path,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'Key:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.secondaryColor,
                        ),
                  ),
                  const SizedBox(width: 8),
                  SelectableText(
                    result!.key,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Value content
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: result!.value.isNotEmpty
                ? SingleChildScrollView(
                    child: isJson
                        ? JsonViewer(data: result!.value)
                        : SelectableText(
                            result!.value,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                  )
                : const Center(
                    child: Text('(no value)'),
                  ),
          ),
        ),
      ],
    );
  }

  bool _isJson(String value) {
    if (value.isEmpty) return false;
    final trimmed = value.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
           (trimmed.startsWith('[') && trimmed.endsWith(']'));
  }
}