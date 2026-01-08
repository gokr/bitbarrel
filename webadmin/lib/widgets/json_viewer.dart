import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// A widget for displaying JSON data with syntax highlighting and collapsible nodes
class JsonViewer extends StatelessWidget {
  final String data;
  final bool initiallyExpanded;

  const JsonViewer({
    super.key,
    required this.data,
    this.initiallyExpanded = true,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return Text(
        '(empty)',
        style: TextStyle(
          color: AppTheme.secondaryColor.withValues(alpha: 0.5),
          fontStyle: FontStyle.italic,
        ),
      );
    }

    try {
      final parsed = json.decode(data);
      return SingleChildScrollView(
        child: _JsonNode(
          value: parsed,
          initiallyExpanded: initiallyExpanded,
        ),
      );
    } catch (_) {
      // Not valid JSON, display as raw text
      return SelectableText(
        data,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
        ),
      );
    }
  }
}

/// Internal widget for rendering a JSON node
class _JsonNode extends StatefulWidget {
  final dynamic value;
  final String? keyName;
  final bool initiallyExpanded;
  final bool isLast;

  const _JsonNode({
    required this.value,
    this.keyName,
    this.initiallyExpanded = true,
    this.isLast = true,
  });

  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.value == null) {
      return _buildLeaf('null', _nullColor);
    }

    if (widget.value is bool) {
      return _buildLeaf(widget.value.toString(), _boolColor);
    }

    if (widget.value is num) {
      return _buildLeaf(widget.value.toString(), _numberColor);
    }

    if (widget.value is String) {
      return _buildLeaf('"${widget.value}"', _stringColor);
    }

    if (widget.value is List) {
      return _buildArray(widget.value as List);
    }

    if (widget.value is Map) {
      return _buildObject(widget.value as Map<String, dynamic>);
    }

    return _buildLeaf(widget.value.toString(), AppTheme.secondaryColor);
  }

  Widget _buildLeaf(String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.keyName != null) ...[
          SelectableText(
            '"${widget.keyName}": ',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: _keyColor,
            ),
          ),
        ],
        Flexible(
          child: SelectableText(
            text + (widget.isLast ? '' : ','),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArray(List items) {
    if (items.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.keyName != null) ...[
            SelectableText(
              '"${widget.keyName}": ',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: _keyColor,
              ),
            ),
          ],
          Text(
            '[]${widget.isLast ? '' : ','}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: _bracketColor,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: AppTheme.secondaryColor,
              ),
              if (widget.keyName != null) ...[
                SelectableText(
                  '"${widget.keyName}": ',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: _keyColor,
                  ),
                ),
              ],
              Text(
                _isExpanded ? '[' : '[...]${widget.isLast ? '' : ','}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _bracketColor,
                ),
              ),
              if (!_isExpanded) ...[
                Text(
                  ' (${items.length} items)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppTheme.secondaryColor.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_isExpanded) ...[
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++)
                  _JsonNode(
                    value: items[i],
                    initiallyExpanded: false,
                    isLast: i == items.length - 1,
                  ),
              ],
            ),
          ),
          Text(
            ']${widget.isLast ? '' : ','}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: _bracketColor,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildObject(Map<String, dynamic> obj) {
    if (obj.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.keyName != null) ...[
            SelectableText(
              '"${widget.keyName}": ',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: _keyColor,
              ),
            ),
          ],
          Text(
            '{}${widget.isLast ? '' : ','}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: _bracketColor,
            ),
          ),
        ],
      );
    }

    final keys = obj.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: AppTheme.secondaryColor,
              ),
              if (widget.keyName != null) ...[
                SelectableText(
                  '"${widget.keyName}": ',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: _keyColor,
                  ),
                ),
              ],
              Text(
                _isExpanded ? '{' : '{...}${widget.isLast ? '' : ','}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: _bracketColor,
                ),
              ),
              if (!_isExpanded) ...[
                Text(
                  ' (${keys.length} keys)',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppTheme.secondaryColor.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_isExpanded) ...[
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < keys.length; i++)
                  _JsonNode(
                    keyName: keys[i],
                    value: obj[keys[i]],
                    initiallyExpanded: false,
                    isLast: i == keys.length - 1,
                  ),
              ],
            ),
          ),
          Text(
            '}${widget.isLast ? '' : ','}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: _bracketColor,
            ),
          ),
        ],
      ],
    );
  }

  // Colors for syntax highlighting
  static const Color _keyColor = Color(0xFF0077AA);      // Blue for keys
  static const Color _stringColor = Color(0xFF669900);   // Green for strings
  static const Color _numberColor = Color(0xFF990055);   // Purple for numbers
  static const Color _boolColor = Color(0xFF990055);     // Purple for booleans
  static const Color _nullColor = Color(0xFF708090);     // Gray for null
  static const Color _bracketColor = Color(0xFF4A5568);  // Dark gray for brackets
}
