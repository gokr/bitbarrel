import 'package:test/test.dart';
import 'package:bitbarrel/bitbarrel.dart';

void main() {
  group('BarrelStats', () {
    test('creates empty stats object', () {
      const stats = BarrelStats.empty();

      expect(stats.totalKeys, 0);
      expect(stats.activeKeys, 0);
      expect(stats.deletedKeys, 0);
      expect(stats.fileCount, 0);
      expect(stats.totalSize, 0);
      expect(stats.fragmentationRatio, 0.0);
      expect(stats.isCompacting, false);
    });

    test('creates from JSON', () {
      final json = {
        'totalKeys': 100,
        'activeKeys': 90,
        'deletedKeys': 10,
        'fileCount': 3,
        'totalSize': 1048576,
        'activeFileSize': 524288,
        'avgKeySize': 8.5,
        'avgValueSize': 256.0,
        'avgRecordSize': 264.5,
        'fragmentationRatio': 0.15,
        'isCompacting': false,
        'lastCompactTime': '2026-01-02T10:00:00Z',
        'recordsScanned': 1000,
        'recordsKept': 850,
        'recordsDropped': 150,
        'indexMode': 'bmHash',
        'syncMode': 'sync',
        'dataPath': 'test.db',
        'lastModified': '2026-01-02T09:00:00Z',
      };

      final stats = BarrelStats.fromJson(json);

      expect(stats.totalKeys, 100);
      expect(stats.activeKeys, 90);
      expect(stats.deletedKeys, 10);
      expect(stats.fileCount, 3);
      expect(stats.totalSize, 1048576);
      expect(stats.activeFileSize, 524288);
      expect(stats.avgKeySize, 8.5);
      expect(stats.avgValueSize, 256.0);
      expect(stats.avgRecordSize, 264.5);
      expect(stats.fragmentationRatio, 0.15);
      expect(stats.isCompacting, false);
      expect(stats.lastCompactTime, '2026-01-02T10:00:00Z');
      expect(stats.recordsScanned, 1000);
      expect(stats.recordsKept, 850);
      expect(stats.recordsDropped, 150);
      expect(stats.indexMode, 'bmHash');
      expect(stats.syncMode, 'sync');
      expect(stats.dataPath, 'test.db');
      expect(stats.lastModified, '2026-01-02T09:00:00Z');
    });

    test('handles missing JSON fields', () {
      final json = <String, dynamic>{
        'totalKeys': 50,
      };

      final stats = BarrelStats.fromJson(json);

      expect(stats.totalKeys, 50);
      expect(stats.activeKeys, 0);
      expect(stats.deletedKeys, 0);
    });

    test('toString provides summary', () {
      const stats = BarrelStats(
        totalKeys: 100,
        activeKeys: 90,
        deletedKeys: 10,
        fileCount: 3,
        totalSize: 1048576,
        activeFileSize: 524288,
        avgKeySize: 8.5,
        avgValueSize: 256.0,
        avgRecordSize: 264.5,
        fragmentationRatio: 0.15,
        isCompacting: false,
        lastCompactTime: '2026-01-02T10:00:00Z',
        recordsScanned: 1000,
        recordsKept: 850,
        recordsDropped: 150,
        indexMode: 'bmHash',
        syncMode: 'sync',
        dataPath: 'test.db',
        lastModified: '2026-01-02T09:00:00Z',
      );

      final str = stats.toString();
      expect(str, contains('totalKeys: 100'));
      expect(str, contains('activeKeys: 90'));
      expect(str, contains('deletedKeys: 10'));
      expect(str, contains('totalSize: 1048576 bytes'));
      expect(str, contains('fragmentation: 15.0%'));
    });
  });

  group('Command', () {
    test('getBarrelStats constant value', () {
      expect(Command.getBarrelStats, 0x18);
    });

    test('validates getBarrelStats command', () {
      expect(Command.isValid(Command.getBarrelStats), true);
    });
  });
}
