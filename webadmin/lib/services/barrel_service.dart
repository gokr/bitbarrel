import 'package:bitbarrel/bitbarrel.dart';
import 'package:flutter/foundation.dart';
import 'package:bitbarrel_admin/models/barrel.dart';
import 'package:bitbarrel_admin/models/barrel_config.dart';
import 'connection_service.dart';

/// Service for managing BitBarrel barrels
class BarrelService extends ChangeNotifier {
  final ConnectionService _connectionService;

  // Observable states using ValueNotifier
  final ValueNotifier<List<Barrel>> barrels = ValueNotifier([]);
  final ValueNotifier<Barrel?> currentBarrel = ValueNotifier(null);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);

  BarrelService(this._connectionService);

  BitBarrelClient? get _client => _connectionService.client;

  /// Load all barrels from the server
  Future<void> loadBarrels() async {
    if (_client == null) {
      error.value = 'Not connected to server';
      return;
    }

    isLoading.value = true;
    error.value = null;

    try {
      final barrelNames = await _client!.listBarrels();

      barrels.value = [];
      for (final name in barrelNames) {
        // Try to get barrel config if possible
        String? config;
        try {
          config = await _client!.getBarrelConfig(name);
        } catch (e) {
          // Ignore errors for individual barrels
        }

        barrels.value = [...barrels.value, Barrel(
          name: name,
          config: config,
        )];
      }
    } catch (e) {
      error.value = 'Failed to load barrels: $e';
    } finally {
      isLoading.value = false;
    }
  }

  /// Create a new barrel
  Future<void> createBarrel(String name, {String? config}) async {
    if (_client == null) {
      error.value = 'Not connected to server';
      throw Exception('Not connected to server');
    }

    isLoading.value = true;
    error.value = null;

    try {
      await _client!.createBarrel(name, config ?? "");

      // Reload barrels
      await loadBarrels();
    } catch (e) {
      error.value = 'Failed to create barrel: $e';
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Delete a barrel
  Future<void> deleteBarrel(String name) async {
    if (_client == null) {
      error.value = 'Not connected to server';
      return;
    }

    isLoading.value = true;
    error.value = null;

    try {
      await _client!.dropBarrel(name);

      // Remove from local list
      barrels.value = barrels.value.where((b) => b.name != name).toList();

      // Clear current barrel if it was deleted
      if (currentBarrel.value?.name == name) {
        currentBarrel.value = null;
      }
    } catch (e) {
      error.value = 'Failed to delete barrel: $e';
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Select a barrel for use
  Future<void> useBarrel(String name) async {
    if (_client == null) {
      error.value = 'Not connected to server';
      return;
    }

    isLoading.value = true;
    error.value = null;

    try {
      await _client!.useBarrel(name);

      // Find barrel in list and set as current
      final barrel = barrels.value.firstWhere(
        (b) => b.name == name,
        orElse: () => Barrel(name: name),
      );

      currentBarrel.value = barrel;
    } catch (e) {
      error.value = 'Failed to select barrel: $e';
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// Reload current barrel config
  Future<void> reloadCurrentBarrelConfig() async {
    final barrel = currentBarrel.value;
    if (barrel == null || _client == null) return;

    try {
      final config = await _client!.getBarrelConfig(barrel.name);
      currentBarrel.value = barrel.copyWith(config: config);
    } catch (e) {
      // Ignore error
    }
  }

  /// Get barrel configuration as raw JSON string
  Future<String> getBarrelConfigRaw(String name) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }
    return await _client!.getBarrelConfig(name);
  }

  /// Set barrel configuration from raw JSON string
  Future<void> setBarrelConfigRaw(String name, String config) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }
    await _client!.setBarrelConfig(name, config);
  }

  /// Get barrel configuration as BarrelConfig model
  Future<BarrelConfig> getBarrelConfig(String name) async {
    final jsonStr = await getBarrelConfigRaw(name);
    return BarrelConfig.fromJsonString(jsonStr);
  }

  /// Update barrel configuration
  Future<BarrelConfig> updateBarrelConfig(String name, BarrelConfig config) async {
    if (_client == null) {
      throw Exception('Not connected to server');
    }

    final jsonStr = config.toJsonString();
    await _client!.setBarrelConfig(name, jsonStr);

    // Reload the config to get any server-side modifications
    return await getBarrelConfig(name);
  }

  /// Clear current barrel selection
  void clearCurrentBarrel() {
    currentBarrel.value = null;
  }

  /// Dispose resources
  @override
  void dispose() {
    barrels.dispose();
    currentBarrel.dispose();
    isLoading.dispose();
    error.dispose();
    super.dispose();
  }
}
