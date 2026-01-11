import 'package:flutter/material.dart';
import 'package:watch_it/watch_it.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Screen for displaying barrel statistics and metrics
class BarrelStatsScreen extends StatefulWidget with WatchItStatefulWidgetMixin {
  const BarrelStatsScreen({super.key});

  @override
  State<BarrelStatsScreen> createState() => _BarrelStatsScreenState();
}

class _BarrelStatsScreenState extends State<BarrelStatsScreen> {
  Map<String, dynamic>? _stats;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final barrel = di<BarrelService>().currentBarrel.value;
    if (barrel == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final client = di<ConnectionService>().client;
      if (client == null) {
        throw Exception('Not connected to server');
      }

      final stats = await client.getBarrelStats(barrel.name);

      setState(() {
        _stats = {
          'totalKeys': stats.totalKeys,
          'activeKeys': stats.activeKeys,
          'deletedKeys': stats.deletedKeys,
          'fileCount': stats.fileCount,
          'totalSize': stats.totalSize,
          'activeFileSize': stats.activeFileSize,
          'avgKeySize': stats.avgKeySize,
          'avgValueSize': stats.avgValueSize,
          'avgRecordSize': stats.avgRecordSize,
          'fragmentationRatio': stats.fragmentationRatio,
          'isCompacting': stats.isCompacting,
          'lastCompactTime': stats.lastCompactTime,
          'recordsScanned': stats.recordsScanned,
          'recordsKept': stats.recordsKept,
          'recordsDropped': stats.recordsDropped,
          'indexMode': stats.indexMode,
          'syncMode': stats.syncMode,
          'dataPath': stats.dataPath,
          'lastModified': stats.lastModified,
        };
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load statistics: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshStats() async {
    await _loadStats();
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    Color? iconColor,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor ?? AppTheme.primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid() {
    if (_stats == null) return const SizedBox.shrink();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      crossAxisSpacing: 16,
      mainAxisSpacing: 16,
      children: [
        _buildStatCard(
          title: 'Total Keys',
          value: _stats!['totalKeys'].toString(),
          icon: Icons.storage,
          iconColor: AppTheme.primaryColor,
        ),
        _buildStatCard(
          title: 'Active Keys',
          value: _stats!['activeKeys'].toString(),
          icon: Icons.check_circle,
          iconColor: AppTheme.successColor,
        ),
        _buildStatCard(
          title: 'Deleted Keys',
          value: _stats!['deletedKeys'].toString(),
          icon: Icons.delete,
          iconColor: AppTheme.errorColor,
        ),
        _buildStatCard(
          title: 'Disk Usage',
          value: '${(_stats!['totalSize'] / 1024 / 1024).toStringAsFixed(2)} MB',
          icon: Icons.sd_card,
          iconColor: AppTheme.secondaryColor,
        ),
      ],
    );
  }

  Widget _buildPerformanceMetrics() {
    if (_stats == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Performance Metrics',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildMetricRow('Avg Key Size', '${_stats!['avgKeySize'].toStringAsFixed(2)} bytes'),
            _buildMetricRow('Avg Value Size', '${_stats!['avgValueSize'].toStringAsFixed(2)} bytes'),
            _buildMetricRow('Avg Record Size', '${_stats!['avgRecordSize'].toStringAsFixed(2)} bytes'),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactionInfo() {
    if (_stats == null) return const SizedBox.shrink();

    final isCompacting = _stats!['isCompacting'] as bool? ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Compaction Status',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isCompacting ? AppTheme.errorColor.withValues(alpha: 0.1) : AppTheme.successColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    isCompacting ? 'In Progress' : 'Idle',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isCompacting ? AppTheme.errorColor : AppTheme.successColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildMetricRow('Fragmentation', '${(_stats!['fragmentationRatio'] * 100).toStringAsFixed(1)}%'),
            _buildMetricRow('Files', _stats!['fileCount'].toString()),
            if (_stats!['lastCompactTime'] != null && _stats!['lastCompactTime'].toString().isNotEmpty)
              _buildMetricRow('Last Compaction', _stats!['lastCompactTime'].toString()),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurationInfo() {
    if (_stats == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Configuration',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildMetricRow('Index Mode', _stats!['indexMode'].toString()),
            _buildMetricRow('Sync Mode', _stats!['syncMode'].toString()),
            _buildMetricRow('Data Path', _stats!['dataPath'].toString()),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final barrel = watchValue((BarrelService s) => s.currentBarrel);

    if (barrel == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Barrel Statistics')),
        body: const Center(child: Text('No barrel selected')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${barrel.name} - Statistics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refreshStats,
            tooltip: 'Refresh statistics',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: AppTheme.errorColor, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load statistics',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(color: AppTheme.errorColor),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _loadStats,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try Again'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildStatsGrid(),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildPerformanceMetrics(),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildCompactionInfo(),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildConfigurationInfo(),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
    );
  }
}
