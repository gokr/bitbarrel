import 'package:flutter/material.dart';
import 'package:watch_it/watch_it.dart';
import 'package:bitbarrel_admin/models/barrel_config.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Dialog for editing barrel configuration
class BarrelConfigDialog extends StatefulWidget {
  final String barrelName;
  final BarrelConfig? initialConfig;

  const BarrelConfigDialog({
    super.key,
    required this.barrelName,
    this.initialConfig,
  });

  /// Show the dialog and return the updated config or null if cancelled
  static Future<BarrelConfig?> show(
    BuildContext context, {
    required String barrelName,
    BarrelConfig? initialConfig,
  }) {
    return showDialog<BarrelConfig?>(
      context: context,
      builder: (context) => BarrelConfigDialog(
        barrelName: barrelName,
        initialConfig: initialConfig,
      ),
    );
  }

  @override
  State<BarrelConfigDialog> createState() => _BarrelConfigDialogState();
}

class _BarrelConfigDialogState extends State<BarrelConfigDialog> {
  late final TextEditingController _writeBufferController;
  late final TextEditingController _readBufferController;
  late final TextEditingController _maxFileSizeController;
  late final TextEditingController _compactionThresholdController;

  String _syncMode = 'none';
  bool _autoCompact = true;
  bool _isLoading = false;
  String? _error;
  BarrelConfig? _loadedConfig;

  @override
  void initState() {
    super.initState();

    _writeBufferController = TextEditingController(
      text: (widget.initialConfig?.writeBufferSize ?? 65536).toString(),
    );
    _readBufferController = TextEditingController(
      text: (widget.initialConfig?.readBufferSize ?? 65536).toString(),
    );
    _maxFileSizeController = TextEditingController(
      text: (widget.initialConfig?.maxDataFileSize ?? 536870912).toString(),
    );
    _compactionThresholdController = TextEditingController(
      text: (widget.initialConfig?.compactionThreshold ?? 50).toString(),
    );
    _syncMode = widget.initialConfig?.syncMode ?? 'none';
    _autoCompact = widget.initialConfig?.autoCompact ?? true;

    // Load config if not provided
    if (widget.initialConfig == null) {
      _loadConfig();
    }
  }

  @override
  void dispose() {
    _writeBufferController.dispose();
    _readBufferController.dispose();
    _maxFileSizeController.dispose();
    _compactionThresholdController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() => _isLoading = true);
    try {
      final config = await di<BarrelService>().getBarrelConfig(widget.barrelName);
      setState(() {
        _loadedConfig = config;
        _syncMode = config.syncMode;
        _autoCompact = config.autoCompact;
        _writeBufferController.text = config.writeBufferSize.toString();
        _readBufferController.text = config.readBufferSize.toString();
        _maxFileSizeController.text = config.maxDataFileSize.toString();
        _compactionThresholdController.text = config.compactionThreshold.toString();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load config: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    final writeBuffer = int.tryParse(_writeBufferController.text) ?? 65536;
    final readBuffer = int.tryParse(_readBufferController.text) ?? 65536;
    final maxFileSize = int.tryParse(_maxFileSizeController.text) ?? 536870912;
    final compactionThreshold = int.tryParse(_compactionThresholdController.text) ?? 50;

    if (writeBuffer <= 0 || readBuffer <= 0 || maxFileSize <= 0 || compactionThreshold < 0 || compactionThreshold > 100) {
      setState(() => _error = 'Invalid values: buffer sizes must be positive, compaction threshold must be 0-100');
      return;
    }

    final config = BarrelConfig(
      mode: _loadedConfig?.mode ?? 'bmHash',
      syncMode: _syncMode,
      writeBufferSize: writeBuffer,
      readBufferSize: readBuffer,
      autoCompact: _autoCompact,
      compactionThreshold: compactionThreshold,
      maxDataFileSize: maxFileSize,
    );

    setState(() => _isLoading = true);
    try {
      final updatedConfig = await di<BarrelService>().updateBarrelConfig(widget.barrelName, config);
      if (mounted) {
        Navigator.of(context).pop(updatedConfig);
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to save config: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = _loadedConfig?.mode ?? widget.initialConfig?.mode ?? 'bmHash';

    return AlertDialog(
      title: Text('Configure: ${widget.barrelName}'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.5,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mode display (read-only)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.cardColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Index Mode',
                            style: TextStyle(fontSize: 12, color: AppTheme.secondaryColor),
                          ),
                          Text(
                            mode == 'bmHash' ? 'Hash (bmHash)' :
                            mode == 'bmCritBit' ? 'CritBit (bmCritBit)' :
                            'HugeCritBit (bmHugeCritBit)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Sync mode
              const Text('Sync Mode', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _syncMode,
                decoration: const InputDecoration(),
                items: [
                  for (final mode in SyncModes.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(SyncModes.displayName(mode)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _syncMode = v);
                },
              ),
              const SizedBox(height: 16),

              // Buffer sizes
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Write Buffer Size', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _writeBufferController,
                          decoration: const InputDecoration(
                            suffixText: 'bytes',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Read Buffer Size', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _readBufferController,
                          decoration: const InputDecoration(
                            suffixText: 'bytes',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Max file size
              const Text('Max Data File Size', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _maxFileSizeController,
                decoration: const InputDecoration(
                  suffixText: 'bytes',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),

              // Auto compact toggle
              Row(
                children: [
                  Switch(
                    value: _autoCompact,
                    onChanged: (v) => setState(() => _autoCompact = v),
                  ),
                  const Text('Auto Compact'),
                ],
              ),
              const SizedBox(height: 8),

              // Compaction threshold slider
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Compaction Threshold'),
                      const Spacer(),
                      Text('${_compactionThresholdController.text}%'),
                    ],
                  ),
                  Slider(
                    value: double.tryParse(_compactionThresholdController.text) ?? 50,
                    min: 0,
                    max: 100,
                    divisions: 20,
                    onChanged: (v) {
                      setState(() {
                        _compactionThresholdController.text = v.round().toString();
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Error message
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveConfig,
          style: AppTheme.primaryButtonStyle,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}