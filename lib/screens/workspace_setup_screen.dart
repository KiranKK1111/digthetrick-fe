/// Workspace setup — drives `/api/workspaces`.
///
/// Layout:
///   - Top: name field + driver pickers per slot (relational / vector / cache / blob)
///   - Middle: driver-specific form fields rendered from the catalog
///   - Bottom: Probe → 10-step report → Save + Activate
///
/// First-launch flow: SplashScreen navigates here. After Save+Activate
/// the user hits Back and Splash transitions to the main shell.
library;

import 'package:flutter/material.dart';

import '../services/api_service.dart';

class WorkspaceSetupScreen extends StatefulWidget {
  const WorkspaceSetupScreen({super.key, required this.baseUrl});

  final String baseUrl;

  @override
  State<WorkspaceSetupScreen> createState() => _WorkspaceSetupScreenState();
}

class _WorkspaceSetupScreenState extends State<WorkspaceSetupScreen> {
  late final ApiService _api = ApiService(baseUrl: widget.baseUrl);
  Map<String, dynamic>? _catalog;
  String? _loadError;

  final _nameCtrl = TextEditingController(text: 'default');
  final Map<String, String?> _selectedDriver = {
    'relational': 'postgres',
    'vector': 'qdrant',
    'cache': 'redis',
    'blob': 'filesystem',
  };
  // slot → field → controller for text inputs.
  final Map<String, Map<String, TextEditingController>> _ctrls = {};
  final Map<String, Map<String, bool>> _bools = {};
  List<Map<String, dynamic>>? _probeSteps;
  String? _probeMessage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final m in _ctrls.values) {
      for (final c in m.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final cat = await _api.getWorkspaceDriverCatalog();
      setState(() => _catalog = cat);
    } catch (e) {
      setState(() => _loadError = '$e');
    }
  }

  List<Map<String, dynamic>> _fieldsFor(String? driverId) {
    if (driverId == null || _catalog == null) return const [];
    final entry = _catalog![driverId] as Map<String, dynamic>?;
    if (entry == null) return const [];
    return (entry['fields'] as List).cast<Map<String, dynamic>>();
  }

  TextEditingController _ctrl(String slot, Map<String, dynamic> field) {
    final byField = _ctrls.putIfAbsent(slot, () => {});
    return byField.putIfAbsent(field['name'] as String, () {
      final def = field['default'];
      return TextEditingController(text: def?.toString() ?? '');
    });
  }

  bool _boolValue(String slot, Map<String, dynamic> field) {
    final byField = _bools.putIfAbsent(slot, () => {});
    return byField.putIfAbsent(field['name'] as String, () {
      final def = field['default'];
      return def is bool ? def : false;
    });
  }

  Map<String, dynamic> _slotBody(String slot) {
    final driver = _selectedDriver[slot];
    if (driver == null) return {};
    final out = <String, dynamic>{'driver': driver};
    for (final f in _fieldsFor(driver)) {
      final name = f['name'] as String;
      final ftype = f['type'] as String? ?? 'string';
      if (ftype == 'bool') {
        out[name] = _bools[slot]?[name] ?? false;
      } else if (ftype == 'int') {
        final v = _ctrls[slot]?[name]?.text ?? '';
        if (v.isNotEmpty) {
          out[name] = int.tryParse(v) ?? 0;
        }
      } else {
        final v = _ctrls[slot]?[name]?.text ?? '';
        if (v.isNotEmpty) out[name] = v;
      }
    }
    return out;
  }

  Map<String, dynamic> _buildBody() => {
        'name': _nameCtrl.text.trim().isEmpty ? 'default' : _nameCtrl.text.trim(),
        'relational': _slotBody('relational'),
        'vector': _slotBody('vector'),
        'cache': _slotBody('cache'),
        'blob': _slotBody('blob'),
      };

  Future<void> _saveAndActivate() async {
    setState(() {
      _busy = true;
      _probeMessage = null;
    });
    final body = _buildBody();
    try {
      await _api.upsertWorkspace(body);
      await _api.activateWorkspace(body['name'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Workspace "${body['name']}" saved & activated.')),
      );
      // Pop with `true` so the caller (Splash) knows the workspace is
      // ready and can proceed into the main shell without re-probing.
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _probeMessage = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _probeSteps = null;
      _probeMessage = null;
    });
    final body = _buildBody();
    try {
      await _api.upsertWorkspace(body);
      final result = await _api.probeWorkspace(body['name'] as String);
      setState(() {
        _probeSteps = (result['steps'] as List).cast<Map<String, dynamic>>();
        _probeMessage = (result['overall_ok'] as bool? ?? false)
            ? 'All steps passed.'
            : 'See step details below.';
      });
    } catch (e) {
      setState(() => _probeMessage = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Workspace setup')),
      body: _catalog == null
          ? Center(
              child: _loadError != null
                  ? Text('Could not load drivers: $_loadError')
                  : const CircularProgressIndicator(),
            )
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Workspace name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _slotSection('Relational database', 'relational'),
                      _slotSection('Vector store', 'vector'),
                      _slotSection('Cache (optional)', 'cache'),
                      _slotSection('Blob store', 'blob'),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _probe,
                            icon: const Icon(Icons.network_check),
                            label: const Text('Probe connections'),
                          ),
                          FilledButton.icon(
                            onPressed: _busy ? null : _saveAndActivate,
                            icon: const Icon(Icons.save),
                            label: const Text('Save & activate'),
                          ),
                        ],
                      ),
                      if (_probeMessage != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _probeMessage!,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                      if (_probeSteps != null) _probeReport(_probeSteps!),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _slotSection(String label, String slot) {
    final theme = Theme.of(context);
    final drivers = _catalog!.entries
        .where((e) =>
            (e.value as Map<String, dynamic>)['kind'] == _slotKind(slot))
        .toList();
    final selected = _selectedDriver[slot];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          DropdownButtonFormField<String?>(
            initialValue: selected,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              if (slot == 'cache')
                const DropdownMenuItem<String?>(value: null, child: Text('(no cache)')),
              for (final d in drivers)
                DropdownMenuItem<String?>(
                  value: d.key,
                  child: Text((d.value as Map)['label'] as String? ?? d.key),
                ),
            ],
            onChanged: (v) => setState(() => _selectedDriver[slot] = v),
          ),
          if (selected != null) ...[
            const SizedBox(height: 6),
            for (final f in _fieldsFor(selected)) _fieldRow(slot, f),
          ],
        ],
      ),
    );
  }

  String _slotKind(String slot) => switch (slot) {
        'relational' => 'relational',
        'vector' => 'vector',
        'cache' => 'cache',
        'blob' => 'blob',
        _ => 'relational',
      };

  Widget _fieldRow(String slot, Map<String, dynamic> field) {
    final ftype = field['type'] as String? ?? 'string';
    final secret = field['secret'] as bool? ?? false;
    final required = field['required'] as bool? ?? true;
    final baseLabel = field['label'] as String? ?? field['name'] as String;
    // Optional fields read "Label (optional)" so an empty field
    // doesn't look like a missing-required-input bug. Self-hosted
    // Qdrant in particular has no API key — see Architecture
    // discussion on local-only deploys.
    final label = required ? baseLabel : '$baseLabel  (optional)';
    if (ftype == 'bool') {
      return SwitchListTile(
        title: Text(label),
        subtitle: (field['notes'] as String?)?.isNotEmpty == true
            ? Text(field['notes'] as String)
            : null,
        contentPadding: EdgeInsets.zero,
        value: _boolValue(slot, field),
        onChanged: (v) => setState(() {
          _bools.putIfAbsent(slot, () => {})[field['name'] as String] = v;
        }),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextField(
        controller: _ctrl(slot, field),
        keyboardType: ftype == 'int' ? TextInputType.number : TextInputType.text,
        obscureText: secret,
        decoration: InputDecoration(
          labelText: label,
          helperText: field['notes'] as String?,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _probeReport(List<Map<String, dynamic>> steps) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          for (final s in steps)
            ListTile(
              leading: Icon(
                (s['ok'] as bool? ?? false) ? Icons.check_circle : Icons.error,
                color: (s['ok'] as bool? ?? false) ? Colors.green : Colors.red,
                size: 20,
              ),
              dense: true,
              title: Text(s['name'] as String? ?? ''),
              subtitle: Text(s['detail'] as String? ?? ''),
              trailing: Text('${s['latency_ms'] ?? 0} ms'),
            ),
        ],
      ),
    );
  }
}
