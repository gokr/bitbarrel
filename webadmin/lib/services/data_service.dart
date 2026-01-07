import 'package:bitbarrel/bitbarrel.dart';
import 'package:flutter/foundation.dart';
import 'package:bitbarrel_admin/models/key_value_item.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';

/// Service for data operations (CRUD and queries)
class DataService extends ChangeNotifier {
  final ConnectionService _connectionService;
  final BarrelService _barrelService;

  // Observable states using ValueNotifier
  final ValueNotifier<List<KeyValueItem>> items = ValueNotifier([]);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final ValueNotifier<String> currentCursor = ValueNotifier('');
  final ValueNotifier<bool> hasMore = ValueNotifier(false);
  final ValueNotifier<int> totalCount = ValueNotifier(0);
  final ValueNotifier<String> searchQuery = ValueNotifier('');

  // All keys cache for client-side filtering (Hash mode)
  List<String> _allKeys = [];

  // Page size for queries
  static const int pageSize = 50;

  DataService(this._connectionService, this._barrelService);

  BitBarrelClient? get _client => _connectionService.client;

  /// Check if current barrel supports range queries (CritBit mode)
  bool get supportsRangeQueries {
    final barrel = _barrelService.currentBarrel.value;
    return barrel?.supportsRangeQueries ?? false;
  }

  /// Load keys from the current barrel
  Future<void> loadKeys({int limit = pageSize}) async {
    if (_client == null) {
      error.value = 'Not connected to server';
      return;
    }

    if (_barrelService.currentBarrel.value == null) {
      error.value = 'No barrel selected';
      return;
    }

    isLoading.value = true;
    error.value = null;
    items.value = [];
    currentCursor.value = '';
    hasMore.value = false;

    try {
      // Get total count
      totalCount.value = await _client!.count();

      if (supportsRangeQueries && searchQuery.value.isNotEmpty) {
        // Use prefix query for CritBit mode with search
        await _loadWithPrefixQuery(searchQuery.value, limit);
      } else if (supportsRangeQueries) {
        // Use prefix query with empty prefix for CritBit mode
        await _loadWithPrefixQuery('', limit);
      } else {
        // Use listKeys for Hash mode
        await _loadWithListKeys(limit);
      }
    } catch (e) {
      error.value = 'Failed to load keys: $e';
    } finally {
      isLoading.value = false;
    }
  }

  /// Load keys using listKeys (for Hash mode)
  Future<void> _loadWithListKeys(int limit) async {
    _allKeys = await _client!.listKeys();

    // Apply client-side filter if search query exists
    var filteredKeys = _allKeys;
    if (searchQuery.value.isNotEmpty) {
      final query = searchQuery.value.toLowerCase();
      filteredKeys = _allKeys.where((k) => k.toLowerCase().contains(query)).toList();
    }

    // Paginate client-side
    final pageKeys = filteredKeys.take(limit).toList();
    hasMore.value = filteredKeys.length > limit;

    // Get values for the first page
    final newItems = <KeyValueItem>[];
    for (final key in pageKeys) {
      try {
        final value = await _client!.get(key);
        newItems.add(KeyValueItem(key: key, value: value));
      } catch (e) {
        // Key might have been deleted, skip it
      }
    }

    items.value = newItems;
    currentCursor.value = pageKeys.isNotEmpty ? pageKeys.last : '';
  }

  /// Load keys using prefix query (for CritBit mode)
  Future<void> _loadWithPrefixQuery(String prefix, int limit) async {
    final result = await _client!.prefixQuery(prefix, limit: limit, cursor: '');

    items.value = result.items
        .map((kv) => KeyValueItem(key: kv.key, value: kv.value))
        .toList();

    currentCursor.value = result.nextCursor;
    hasMore.value = result.hasMore;
  }

  /// Load next page of keys
  Future<void> loadNextPage() async {
    if (_client == null || !hasMore.value || isLoading.value) {
      return;
    }

    isLoading.value = true;
    error.value = null;

    try {
      if (supportsRangeQueries) {
        // Use prefix query for CritBit mode
        final prefix = searchQuery.value;
        final result = await _client!.prefixQuery(
          prefix,
          limit: pageSize,
          cursor: currentCursor.value,
        );

        final newItems = result.items
            .map((kv) => KeyValueItem(key: kv.key, value: kv.value))
            .toList();

        items.value = [...items.value, ...newItems];
        currentCursor.value = result.nextCursor;
        hasMore.value = result.hasMore;
      } else {
        // Client-side pagination for Hash mode
        var filteredKeys = _allKeys;
        if (searchQuery.value.isNotEmpty) {
          final query = searchQuery.value.toLowerCase();
          filteredKeys = _allKeys.where((k) => k.toLowerCase().contains(query)).toList();
        }

        // Find next page
        final currentIndex = filteredKeys.indexOf(currentCursor.value);
        final startIndex = currentIndex >= 0 ? currentIndex + 1 : 0;
        final pageKeys = filteredKeys.skip(startIndex).take(pageSize).toList();

        hasMore.value = startIndex + pageKeys.length < filteredKeys.length;

        // Get values for this page
        final newItems = <KeyValueItem>[];
        for (final key in pageKeys) {
          try {
            final value = await _client!.get(key);
            newItems.add(KeyValueItem(key: key, value: value));
          } catch (e) {
            // Key might have been deleted, skip it
          }
        }

        items.value = [...items.value, ...newItems];
        currentCursor.value = pageKeys.isNotEmpty ? pageKeys.last : '';
      }
    } catch (e) {
      error.value = 'Failed to load more keys: $e';
    } finally {
      isLoading.value = false;
    }
  }

  /// Search keys by prefix or substring
  Future<void> searchKeys(String query) async {
    searchQuery.value = query;
    await loadKeys();
  }

  /// Get value for a specific key
  Future<String> getValue(String key) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    return await _client!.get(key);
  }

  /// Set value for a key (create or update)
  Future<void> setValue(String key, String value) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    await _client!.set(key, value);

    // Update local item if it exists
    final idx = items.value.indexWhere((item) => item.key == key);
    if (idx >= 0) {
      final updatedItems = List<KeyValueItem>.from(items.value);
      updatedItems[idx] = KeyValueItem(key: key, value: value);
      items.value = updatedItems;
    } else {
      // Reload to include new key
      await loadKeys();
    }
  }

  /// Delete a key
  Future<void> deleteKey(String key) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    await _client!.delete(key);

    // Remove from local list
    items.value = items.value.where((item) => item.key != key).toList();
    totalCount.value = totalCount.value > 0 ? totalCount.value - 1 : 0;
  }

  /// Perform a range query
  Future<RangeQueryResponse> rangeQuery(
    String startKey,
    String endKey, {
    int limit = pageSize,
    String cursor = '',
  }) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    if (!supportsRangeQueries) {
      throw Exception('Range queries not supported in Hash mode');
    }

    return await _client!.rangeQuery(startKey, endKey, limit: limit, cursor: cursor);
  }

  /// Perform a prefix query
  Future<RangeQueryResponse> prefixQuery(
    String prefix, {
    int limit = pageSize,
    String cursor = '',
  }) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    if (!supportsRangeQueries) {
      throw Exception('Prefix queries not supported in Hash mode');
    }

    return await _client!.prefixQuery(prefix, limit: limit, cursor: cursor);
  }

  /// Perform a reference traversal
  ///
  /// Traverses relationships between keys using path specs like "friends->team"
  /// and returns the results with optional full data inclusion.
  ///
  /// [key] is the starting key to begin traversal from
  /// [pathSpec] is the path specification (e.g., "friends", "friends->team", "*->posts[0:5]")
  /// [includeFullData] if true, includes the full value data in results
  /// [firstOnly] if true, returns only the first matching result
  Future<List<TraverseResult>> traverse(
    String key,
    String pathSpec, {
    bool includeFullData = true,
    bool firstOnly = false,
  }) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    if (_barrelService.currentBarrel.value == null) {
      throw Exception('No barrel selected');
    }

    final options = TraverseOptions(
      includeFullData: includeFullData,
      firstOnly: firstOnly,
    );

    return await _client!.traverse(key, pathSpec, options: options);
  }

  /// Clear current data
  void clear() {
    items.value = [];
    currentCursor.value = '';
    hasMore.value = false;
    totalCount.value = 0;
    searchQuery.value = '';
    error.value = null;
    _allKeys = [];
  }

  /// Dispose resources
  @override
  void dispose() {
    items.dispose();
    isLoading.dispose();
    error.dispose();
    currentCursor.dispose();
    hasMore.dispose();
    totalCount.dispose();
    searchQuery.dispose();
    super.dispose();
  }
}
