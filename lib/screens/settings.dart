/// Settings screen — schema-driven, with first-class LLM provider switching.
///
/// Three providers are wired into the backend: `ollama` (local),
/// `openrouter` (cloud, OpenAI-compatible), and `nvidia` (NVIDIA NIM cloud).
/// Each surfaces its own credentials section. Model selectors are
/// populated live from the active provider's `/models` endpoint so
/// switching provider re-loads the dropdown.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/theme.dart';

// Fields in the LLM section that are model identifiers — these should
// render as live dropdowns populated from /api/settings/llm/models.
const _kModelFields = <String>{
  'model',
  'code_model',
  'vision_model',
  'classifier_model',
};

// Fields that don't apply to every provider. Keyed by provider; only
// shown when the active `provider` matches.
const _kProviderScopedFields = <String, String>{
  'base_url': 'ollama',
  'openrouter_api_key': 'openrouter',
  'openrouter_base_url': 'openrouter',
  'nvidia_api_key': 'nvidia',
  'nvidia_base_url': 'nvidia',
};


class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _schema;
  String? _error;
  bool _busy = false;

  // Live list of models from the active provider. Refreshed on provider
  // switch and via the refresh button.
  List<String> _availableModels = const [];
  bool _modelsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSchema();
    _loadModels();
  }

  ApiService _api() {
    final state = context.read<AppState>();
    return ApiService(baseUrl: state.baseUrl);
  }

  Future<void> _loadSchema() async {
    try {
      final state = context.read<AppState>();
      final schema = await fetchSettingsSchema(state.baseUrl);
      if (!mounted) return;
      setState(() => _schema = schema);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _loadModels() async {
    if (_modelsLoading) return;
    setState(() => _modelsLoading = true);
    try {
      final models = await _api().listLlmModels();
      if (!mounted) return;
      setState(() => _availableModels = models);
    } catch (_) {
      // Unreachable provider — leave the list empty. Model fields then
      // render as plain text inputs the user can still edit.
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  Future<void> _update(Map<String, dynamic> partial) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final updated = await updateAppConfig(state.baseUrl, partial);
      state.replaceConfig(updated);

      // If the user just switched provider, refresh the model list
      // since each provider has its own catalog.
      final llmUpdate = partial['llm'];
      if (llmUpdate is Map && llmUpdate.containsKey('provider')) {
        // Fire and forget — UI updates when it returns.
        // ignore: unawaited_futures
        _loadModels();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Body-only: the RootShell provides the frame (sidebar, header with the
    // back button + window controls), so this screen no longer mounts its
    // own Scaffold/AppBar — it renders inside the main pane like a tab.
    return _schema == null && _error == null
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                  if (_error != null) _ErrorBanner(message: _error!),
                  if (_busy) const LinearProgressIndicator(),
                  // Appearance — theme picker. Lives here (not in the
                  // header) so the header chrome stays clean.
                  _ThemeSection(
                    currentMode: state.themeMode,
                    onChanged: (mode) => state.setThemeMode(mode),
                  ),
                  const SizedBox(height: 16),
                  // Dedicated Database section — has Test / Save buttons
                  // and a live status banner. Rendered before the generic
                  // schema sections; the generic renderer skips
                  // `database` since this widget owns it.
                  _DatabaseSection(
                    initialPostgres: Map<String, dynamic>.from(
                      (state.config.section('database')['postgres'] as Map?)
                              ?.cast<String, dynamic>() ??
                          const {},
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Storage backends (Qdrant + Redis/Dragonfly + blob)
                  // are now configured directly here in Settings —
                  // see the inline sections below.
                  _VectorStoreSection(
                    initial: Map<String, dynamic>.from(
                      (state.config.section('database')['qdrant'] as Map?)
                              ?.cast<String, dynamic>() ??
                          const {},
                    ),
                  ),
                  const SizedBox(height: 12),
                  _CacheSection(
                    initial: Map<String, dynamic>.from(
                      (state.config.section('database')['cache'] as Map?)
                              ?.cast<String, dynamic>() ??
                          const {},
                    ),
                  ),
                  const SizedBox(height: 12),
                  _BlobSection(
                    initial: Map<String, dynamic>.from(
                      (state.config.section('database')['storage'] as Map?)
                              ?.cast<String, dynamic>() ??
                          const {},
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_schema != null) ..._buildSchemaSections(state),
                  const SizedBox(height: 24),
                  _RawConfigDump(config: state.config),
                ],
              ),
            );
  }

  List<Widget> _buildSchemaSections(AppState state) {
    final widgets = <Widget>[];
    final schema = _schema!;
    schema.forEach((sectionName, sectionSchema) {
      if (sectionSchema is! Map) return;
      // `database` has a dedicated widget with Test + Save buttons.
      if (sectionName == 'database') return;
      // `app` carries theme + language. Theme is owned by the
      // _ThemeSection above (frontend-only, no backend round-trip);
      // language is unused while the UI is English-only. Skipping
      // the whole section avoids a duplicate theme picker and an
      // ineffective language dropdown.
      if (sectionName == 'app') return;
      // `llm` (provider / model / key selection + generation knobs) now
      // lives in the dedicated Providers screen — skip it here so there's
      // a single home for LLM configuration.
      if (sectionName == 'llm') return;
      widgets.add(_SchemaSection(
        sectionName: sectionName,
        sectionSchema: sectionSchema.cast<String, dynamic>(),
        currentValues: state.config.section(sectionName),
        availableModels: _availableModels,
        modelsLoading: _modelsLoading,
        onChange: (field, value) =>
            _update({sectionName: {field: value}}),
      ));
      widgets.add(const SizedBox(height: 16));
    });
    return widgets;
  }
}


// ---- Database section: dedicated form + Test/Save buttons ----------------
class _DatabaseSection extends StatefulWidget {
  final Map<String, dynamic> initialPostgres;
  const _DatabaseSection({required this.initialPostgres});

  @override
  State<_DatabaseSection> createState() => _DatabaseSectionState();
}

class _DatabaseSectionState extends State<_DatabaseSection> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _db;
  late final TextEditingController _schema;
  late final TextEditingController _user;
  late final TextEditingController _password;

  bool _testing = false;
  bool _saving = false;
  String? _resultText;
  bool? _resultOk;
  bool? _ready;

  @override
  void initState() {
    super.initState();
    final p = widget.initialPostgres;
    _host = TextEditingController(text: (p['host'] ?? 'localhost').toString());
    _port = TextEditingController(text: (p['port'] ?? 5432).toString());
    _db = TextEditingController(text: (p['db'] ?? '').toString());
    _schema =
        TextEditingController(text: (p['schema_name'] ?? 'public').toString());
    _user = TextEditingController(text: (p['user'] ?? 'postgres').toString());
    _password = TextEditingController(text: '');
    _loadStatus();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _db, _schema, _user, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final state = context.read<AppState>();
      final api = ApiService(baseUrl: state.baseUrl);
      final s = await api.getDatabaseStatus();
      if (!mounted) return;
      setState(() => _ready = s['ready'] == true);
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  Map<String, dynamic> _overrides({bool includePassword = true}) {
    final port = int.tryParse(_port.text.trim()) ?? 5432;
    final out = <String, dynamic>{
      'host': _host.text.trim(),
      'port': port,
      'db': _db.text.trim(),
      'schema_name': _schema.text.trim(),
      'user': _user.text.trim(),
    };
    // Only send password when the user actually typed one — otherwise
    // the backend keeps whatever's already stored.
    final pw = _password.text;
    if (includePassword && pw.isNotEmpty) {
      out['password'] = pw;
    }
    return out;
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _resultText = null;
      _resultOk = null;
    });
    try {
      final state = context.read<AppState>();
      final api = ApiService(baseUrl: state.baseUrl);
      final res = await api.testDatabaseConnection(
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 5432,
        db: _db.text.trim(),
        schemaName: _schema.text.trim(),
        user: _user.text.trim(),
        password: _password.text.isNotEmpty ? _password.text : null,
      );
      final ok = res['ok'] == true;
      if (!mounted) return;
      setState(() {
        _resultOk = ok;
        if (ok) {
          final schemaExists = res['schema_exists'] == true;
          _resultText =
              'Connected. Schema "${res['schema']}" '
              '${schemaExists ? "exists" : "will be created on Save"}.';
        } else {
          _resultText = (res['error'] as String?) ?? 'Connection failed.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _resultText = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _resultText = null;
      _resultOk = null;
    });
    try {
      final state = context.read<AppState>();
      final updates = {
        'database': {'postgres': _overrides(includePassword: true)},
      };
      // updateAppConfig POSTs /api/settings — the backend auto-reinits
      // the engine + runs migrations + creates the schema if missing.
      final updated = await updateAppConfig(state.baseUrl, updates);
      state.replaceConfig(updated);
      // Refresh status banner.
      await _loadStatus();
      if (!mounted) return;
      setState(() {
        _resultOk = _ready;
        _resultText = _ready == true
            ? 'Saved. Schema ensured, migrations applied.'
            : 'Saved, but the database isn\'t reachable. Check the test result above.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _resultText = '$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _testing || _saving;
    return _SectionCard(
      title: 'Database (Postgres)',
      trailing: _StatusDot(ready: _ready),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _row('Host', _host)),
              const SizedBox(width: 8),
              SizedBox(width: 100, child: _row('Port', _port, numeric: true)),
            ],
          ),
          _row('Database', _db),
          _row(
            'Schema',
            _schema,
            help: 'Created automatically if it doesn\'t exist.',
          ),
          _row('User', _user),
          _row(
            'Password',
            _password,
            obscure: true,
            help: 'Leave empty to keep the existing password.',
          ),
          const SizedBox(height: 6),
          if (_resultText != null) _ResultBanner(ok: _resultOk == true, text: _resultText!),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('Test connection'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: busy ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: const Text('Save & migrate'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    bool numeric = false,
    String? help,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                help,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}


class _StatusDot extends StatelessWidget {
  final bool? ready;
  const _StatusDot({required this.ready});

  @override
  Widget build(BuildContext context) {
    final color = ready == null
        ? Colors.grey
        : (ready! ? AppPalette.success : AppPalette.error);
    final label =
        ready == null ? 'checking' : (ready! ? 'connected' : 'degraded');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}


class _ResultBanner extends StatelessWidget {
  final bool ok;
  final String text;
  const _ResultBanner({required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppPalette.success : AppPalette.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12))),
        ],
      ),
    );
  }
}

// ---- Theme section (frontend-only; doesn't round-trip to backend) ----
class _ThemeSection extends StatelessWidget {
  final ThemeMode currentMode;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemeSection({required this.currentMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Appearance',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Theme'),
          const SizedBox(height: 6),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ],
            selected: {currentMode},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ],
      ),
    );
  }
}

// ---- Generic schema-driven section ------------------------------------
class _SchemaSection extends StatelessWidget {
  final String sectionName;
  final Map<String, dynamic> sectionSchema;
  final Map<String, dynamic> currentValues;
  final List<String> availableModels;
  final bool modelsLoading;
  final void Function(String field, dynamic value) onChange;

  const _SchemaSection({
    required this.sectionName,
    required this.sectionSchema,
    required this.currentValues,
    required this.availableModels,
    required this.modelsLoading,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final activeProvider = sectionName == 'llm'
        ? (currentValues['provider'] as String?) ?? 'ollama'
        : null;

    return _SectionCard(
      title: sectionName == 'llm' ? 'LLM provider' : sectionName,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in sectionSchema.entries)
            _buildField(context, entry.key, entry.value, activeProvider),
        ],
      ),
    );
  }

  Widget _buildField(
    BuildContext context,
    String field,
    dynamic spec,
    String? activeProvider,
  ) {
    if (spec is! Map) return const SizedBox.shrink();

    // Provider-scoped fields hide when their provider isn't active.
    final scopedTo = _kProviderScopedFields[field];
    if (scopedTo != null && scopedTo != activeProvider) {
      return const SizedBox.shrink();
    }

    final type = spec['type'] as String?;
    final label = (spec['label'] as String?) ?? field;
    final secret = spec['secret'] == true;
    final value = currentValues[field];

    // Model fields (model / code_model / vision_model / classifier_model)
    // get the live-dropdown treatment so users pick from what the active
    // provider actually has installed/exposed.
    if (sectionName == 'llm' && _kModelFields.contains(field)) {
      return _ModelField(
        label: label,
        currentValue: value?.toString(),
        availableModels: availableModels,
        loading: modelsLoading,
        onChanged: (v) => onChange(field, v ?? ''),
      );
    }

    switch (type) {
      case 'enum':
        final choices = (spec['choices'] as List?)?.cast<String>() ?? const [];
        final implemented =
            (spec['implemented'] as List?)?.cast<String>() ?? choices;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue:
                    (value is String && choices.contains(value)) ? value : null,
                items: [
                  for (final c in choices)
                    DropdownMenuItem(
                      value: c,
                      enabled: implemented.contains(c),
                      child: Text(
                        implemented.contains(c) ? c : '$c (not implemented)',
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) onChange(field, v);
                },
              ),
            ],
          ),
        );

      case 'string':
        return _TextEditor(
          label: label,
          initial: value?.toString() ?? '',
          obscure: secret,
          onSubmit: (v) => onChange(field, v),
        );

      case 'int':
        return _TextEditor(
          label: label,
          initial: value?.toString() ?? '',
          keyboardType: TextInputType.number,
          onSubmit: (v) {
            final i = int.tryParse(v);
            if (i != null) onChange(field, i);
          },
        );

      case 'float':
        return _TextEditor(
          label: label,
          initial: value?.toString() ?? '',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmit: (v) {
            final f = double.tryParse(v);
            if (f != null) onChange(field, f);
          },
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

// ---- Model field: dropdown of available models, plus free-text fallback --
class _ModelField extends StatefulWidget {
  final String label;
  final String? currentValue;
  final List<String> availableModels;
  final bool loading;
  final ValueChanged<String?> onChanged;

  const _ModelField({
    required this.label,
    required this.currentValue,
    required this.availableModels,
    required this.loading,
    required this.onChanged,
  });

  @override
  State<_ModelField> createState() => _ModelFieldState();
}

class _ModelFieldState extends State<_ModelField> {
  bool _editing = false;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentValue ?? '');
  }

  @override
  void didUpdateWidget(covariant _ModelField old) {
    super.didUpdateWidget(old);
    if (old.currentValue != widget.currentValue && !_editing) {
      _ctrl.text = widget.currentValue ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final models = <String>{...widget.availableModels};
    final current = widget.currentValue;
    if (current != null && current.isNotEmpty) models.add(current);

    if (_editing || models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                  labelText: widget.label,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (v) {
                  widget.onChanged(v);
                  setState(() => _editing = false);
                },
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.check),
              onPressed: () {
                widget.onChanged(_ctrl.text);
                setState(() => _editing = false);
              },
            ),
            if (models.isNotEmpty)
              IconButton(
                tooltip: 'Back to list',
                icon: const Icon(Icons.list),
                onPressed: () => setState(() => _editing = false),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue:
                  (current != null && models.contains(current)) ? current : null,
              decoration: InputDecoration(
                labelText: widget.label,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final name in models)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: widget.loading ? null : widget.onChanged,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Type a custom model name',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => setState(() => _editing = true),
          ),
        ],
      ),
    );
  }
}

// ---- Text input that submits on Enter or via the trailing check button -
class _TextEditor extends StatefulWidget {
  final String label;
  final String initial;
  final bool obscure;
  final void Function(String) onSubmit;
  final TextInputType? keyboardType;

  const _TextEditor({
    required this.label,
    required this.initial,
    required this.onSubmit,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final TextEditingController _ctrl;
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void didUpdateWidget(covariant _TextEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial && !_ctrl.text.contains(' ')) {
      _ctrl.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              keyboardType: widget.keyboardType,
              obscureText: widget.obscure && !_reveal,
              autocorrect: !widget.obscure,
              enableSuggestions: !widget.obscure,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.obscure ? '••••••••' : null,
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: widget.obscure
                    ? IconButton(
                        tooltip: _reveal ? 'Hide' : 'Show',
                        icon: Icon(
                          _reveal ? Icons.visibility_off : Icons.visibility,
                          size: 18,
                        ),
                        onPressed: () =>
                            setState(() => _reveal = !_reveal),
                      )
                    : null,
              ),
              onSubmitted: widget.onSubmit,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: () => widget.onSubmit(_ctrl.text),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  /// Optional widget rendered on the right side of the title row.
  /// Used by `_DatabaseSection` to show a connection status dot.
  final Widget? trailing;
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? AppPalette.darkSurface : AppPalette.lightSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? AppPalette.darkBorder : AppPalette.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _RawConfigDump extends StatelessWidget {
  final AppConfig config;
  const _RawConfigDump({required this.config});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExpansionTile(
      title: const Text('Raw config (read-only)'),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: dark ? AppPalette.darkSurfaceAlt : AppPalette.lightSurfaceAlt,
          child: SelectableText(
            _prettyJson(_redact(config.raw)),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Mask API keys in the raw dump — they should never be displayed in cleartext.
  Map<String, dynamic> _redact(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    src.forEach((k, v) {
      if (v is Map) {
        out[k] = _redact(v.cast<String, dynamic>());
      } else if (k.toString().toLowerCase().contains('api_key') &&
          v is String &&
          v.isNotEmpty) {
        out[k] = '••••••••${v.substring(v.length > 4 ? v.length - 4 : 0)}';
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  String _prettyJson(Map<String, dynamic> m) {
    final buf = StringBuffer();
    _writeNode(buf, m, 0);
    return buf.toString();
  }

  void _writeNode(StringBuffer buf, dynamic node, int depth) {
    final pad = '  ' * depth;
    if (node is Map) {
      buf.writeln('{');
      final entries = node.entries.toList();
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        buf.write('$pad  "${e.key}": ');
        _writeNode(buf, e.value, depth + 1);
        if (i < entries.length - 1) buf.write(',');
        buf.writeln();
      }
      buf.write('$pad}');
    } else if (node is List) {
      buf.write('[');
      for (var i = 0; i < node.length; i++) {
        _writeNode(buf, node[i], depth + 1);
        if (i < node.length - 1) buf.write(', ');
      }
      buf.write(']');
    } else if (node is String) {
      buf.write('"$node"');
    } else if (node == null) {
      buf.write('null');
    } else {
      buf.write('$node');
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppPalette.errorBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppPalette.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: AppPalette.error, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Shared base for the three storage-config sections (Qdrant /
/// Cache / Blob). Each section is a small form that POSTs to
/// `/api/settings` with the matching `database.<slot>` subtree.
abstract class _StorageSection extends StatefulWidget {
  const _StorageSection({required this.initial, required this.title});
  final Map<String, dynamic> initial;
  final String title;
}


// ---- Vector store (Qdrant) ----------------------------------------------
class _VectorStoreSection extends _StorageSection {
  const _VectorStoreSection({required super.initial})
      : super(title: 'Vector store (Qdrant)');

  @override
  State<_VectorStoreSection> createState() => _VectorStoreSectionState();
}


class _VectorStoreSectionState extends State<_VectorStoreSection> {
  late final TextEditingController _url;
  late final TextEditingController _grpcPort;
  late final TextEditingController _apiKey;
  bool _preferGrpc = true;
  bool _saving = false;
  String? _result;
  bool? _ok;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _url = TextEditingController(text: (i['url'] ?? 'http://localhost:6333').toString());
    _grpcPort = TextEditingController(text: (i['grpc_port'] ?? 6334).toString());
    _apiKey = TextEditingController(text: '');
    _preferGrpc = (i['prefer_grpc'] as bool?) ?? true;
  }

  @override
  void dispose() {
    for (final c in [_url, _grpcPort, _apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _result = null;
      _ok = null;
    });
    try {
      final state = context.read<AppState>();
      final body = <String, dynamic>{
        'url': _url.text.trim(),
        'grpc_port': int.tryParse(_grpcPort.text.trim()) ?? 6334,
        'prefer_grpc': _preferGrpc,
      };
      if (_apiKey.text.isNotEmpty) body['api_key'] = _apiKey.text;
      final updated = await updateAppConfig(
        state.baseUrl,
        {'database': {'qdrant': body}},
      );
      if (!mounted) return;
      state.replaceConfig(updated);
      setState(() {
        _ok = true;
        _result = 'Saved.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TextRow(label: 'URL', controller: _url),
          const SizedBox(height: 8),
          _TextRow(label: 'gRPC port', controller: _grpcPort, keyboardType: TextInputType.number),
          const SizedBox(height: 8),
          _TextRow(
            label: 'API key  (optional)',
            controller: _apiKey,
            obscure: true,
            helper: 'Leave blank for self-hosted Qdrant on localhost.',
          ),
          SwitchListTile(
            value: _preferGrpc,
            onChanged: (v) => setState(() => _preferGrpc = v),
            title: const Text('Prefer gRPC'),
            contentPadding: EdgeInsets.zero,
          ),
          if (_result != null) ...[
            const SizedBox(height: 4),
            Text(
              _result!,
              style: TextStyle(
                color: _ok == true ? Colors.green : Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}


// ---- Cache (Redis / Dragonfly) ------------------------------------------
class _CacheSection extends _StorageSection {
  const _CacheSection({required super.initial})
      : super(title: 'Cache (Redis / Dragonfly)');

  @override
  State<_CacheSection> createState() => _CacheSectionState();
}


class _CacheSectionState extends State<_CacheSection> {
  late final TextEditingController _url;
  late final TextEditingController _ttl;
  bool _saving = false;
  String? _result;
  bool? _ok;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _url = TextEditingController(text: (i['url'] ?? 'redis://localhost:6379').toString());
    _ttl = TextEditingController(text: (i['default_ttl_seconds'] ?? 3600).toString());
  }

  @override
  void dispose() {
    _url.dispose();
    _ttl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _result = null; _ok = null; });
    try {
      final state = context.read<AppState>();
      final body = <String, dynamic>{
        'url': _url.text.trim(),
        'default_ttl_seconds': int.tryParse(_ttl.text.trim()) ?? 3600,
      };
      final updated = await updateAppConfig(
        state.baseUrl,
        {'database': {'cache': body}},
      );
      if (!mounted) return;
      state.replaceConfig(updated);
      setState(() { _ok = true; _result = 'Saved.'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _ok = false; _result = '$e'; });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TextRow(label: 'URL', controller: _url),
          const SizedBox(height: 8),
          _TextRow(label: 'Default TTL (seconds)', controller: _ttl, keyboardType: TextInputType.number),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Text(
              _result!,
              style: TextStyle(
                color: _ok == true ? Colors.green : Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}


// ---- Blob store (filesystem / MinIO) ------------------------------------
class _BlobSection extends _StorageSection {
  const _BlobSection({required super.initial})
      : super(title: 'Blob storage');

  @override
  State<_BlobSection> createState() => _BlobSectionState();
}


class _BlobSectionState extends State<_BlobSection> {
  late final TextEditingController _path;
  String _backend = 'filesystem';
  bool _saving = false;
  String? _result;
  bool? _ok;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _backend = (i['blobs_backend'] ?? 'filesystem').toString();
    _path = TextEditingController(text: (i['blobs_path'] ?? './data/blobs').toString());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _result = null; _ok = null; });
    try {
      final state = context.read<AppState>();
      final body = <String, dynamic>{
        'blobs_backend': _backend,
        'blobs_path': _path.text.trim(),
      };
      final updated = await updateAppConfig(
        state.baseUrl,
        {'database': {'storage': body}},
      );
      if (!mounted) return;
      state.replaceConfig(updated);
      setState(() { _ok = true; _result = 'Saved.'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _ok = false; _result = '$e'; });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _backend,
            decoration: const InputDecoration(labelText: 'Backend', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'filesystem', child: Text('Filesystem')),
              DropdownMenuItem(value: 'minio', child: Text('MinIO / S3 (config-only)')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _backend = v);
            },
          ),
          const SizedBox(height: 8),
          _TextRow(
            label: _backend == 'filesystem' ? 'Path' : 'Bucket / prefix',
            controller: _path,
            helper: _backend == 'filesystem'
                ? 'Local directory for resume PDFs and solve screenshots.'
                : null,
          ),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Text(
              _result!,
              style: TextStyle(
                color: _ok == true ? Colors.green : Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}


/// Small wrapper around TextField used by the three storage sections.
class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.label,
    required this.controller,
    this.helper,
    this.obscure = false,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final String? helper;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
