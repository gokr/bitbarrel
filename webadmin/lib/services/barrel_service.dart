import 'package:bitbarrel/bitbarrel.dart';
import 'package:observable/observable.dart';
import 'package:bitbarrel_admin/models/barrel.dart';
import 'connection_service.dart';

/// Service for managing BitBarrel barrels
class BarrelService {
  final ConnectionService _connectionService;

  // Observable states
  final ObservableList<Barrel> barrels = ObservableList();
  final Observable<Barrel?> currentBarrel = Observable(null);
  final Observable<bool> isLoading = Observable(false);
  final Observable<String?> error = Observable(null);

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

      barrels.clear();
      for (final name in barrelNames) {
        // Try to get barrel config if possible
        String? config;
        try {
          config = await _client!.getBarrelConfig(name);
        } catch (e) {
          // Ignore errors for individual barrels
        }

        barrels.add(Barrel(
          name: name,
          config: config,
        ));
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
      return;
    }

    isLoading.value = true;
    error.value = null;

    try {
      await _client!.createBarrel(name, config);

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
      barrels.removeWhere((b) => b.name == name);

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
      final barrel = barrels.firstWhere(
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

  /// Clear current barrel selection
  void clearCurrentBarrel() {
    currentBarrel.value = null;
  }

  /// Dispose resources
  void dispose() {
    barrels.clear();
    currentBarrel.value = null;
  }
}
