/// Providers screen — manage the multi-provider LLM catalog, keys, and
/// fallback order.
///
/// Mirrors the freellmapi dashboard, ported to DigTheTrick. Three things
/// live here:
///   * a master "Auto-route" switch that flips `llm.provider` to `auto`,
///   * per-provider API-key management (multiple keys, enable/disable,
///     delete) + live `/models` refresh, and
///   * a reorderable fallback chain with per-model enable + live penalty
///     badges.
///
/// Reached from the sidebar footer (next to Settings). Pushed as its own
/// route, so it owns a Scaffold + AppBar (unlike the IndexedStack tabs).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../data/provider_atlas.dart';
import '../services/api_service.dart';
import '../state/app_state.dart';

class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key});

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _providers = const [];
  List<Map<String, dynamic>> _keys = const [];
  List<Map<String, dynamic>> _fallback = const [];
  String _providerQuery = '';
  // Collapsed provider categories (by title). Reference-only families start
  // collapsed so the routable providers are front-and-centre.
  final Set<String> _collapsedCats = {};
  bool _collapseInit = false;

  ApiService _api() => ApiService(baseUrl: context.read<AppState>().baseUrl);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    setState(() {
      if (!silent) _loading = true;
      _error = null;
    });
    try {
      final api = _api();
      final results = await Future.wait([
        api.listProviders(),
        api.listProviderKeys(),
        api.getFallback(),
      ]);
      if (!mounted) return;
      setState(() {
        _providers = results[0];
        _keys = results[1];
        _fallback = results[2];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _keysFor(String platform) =>
      _keys.where((k) => k['platform'] == platform).toList();

  String get _provider =>
      (context.read<AppState>().config.section('llm')['provider'] as String?) ??
      'ollama';

  Future<void> _setRouting(bool auto) async {
    final state = context.read<AppState>();
    final next = auto ? 'auto' : 'ollama';
    try {
      final updated =
          await updateAppConfig(state.baseUrl, {'llm': {'provider': next}});
      if (!mounted) return;
      state.replaceConfig(updated);
      setState(() {});
      _snack(auto
          ? 'Auto-routing enabled — requests now fall back across providers.'
          : 'Auto-routing off — using the single configured provider.');
    } catch (e) {
      _snack('Could not change routing: $e', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        msg,
        // Pair the text with its background so it's readable in both themes
        // (the default snackbar text color clashed with errorContainer).
        style: TextStyle(
            color: error ? scheme.onErrorContainer : scheme.onInverseSurface),
      ),
      backgroundColor: error ? scheme.errorContainer : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auto = _provider == 'auto';
    // Body-only: the RootShell supplies the frame (sidebar, header with back
    // button + window controls). This renders inside the main pane like a tab.
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          // Tab strip + refresh, in place of the old AppBar.bottom.
          Material(
            color: scheme.surface,
            child: Row(
              children: [
                const Expanded(
                  child: TabBar(
                    tabs: [
                      Tab(text: 'Providers & Keys'),
                      Tab(text: 'Fallback order'),
                      Tab(text: 'Defaults'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          _RoutingBanner(auto: auto, onChanged: _setRouting),
          if (_error != null)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      _buildProvidersTab(),
                      _buildFallbackTab(),
                      _GenerationDefaults(onSaved: (m) => _snack(m)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ---- Providers & keys tab -------------------------------------------
  // Group the routable catalog into the same families as the Atlas, so the
  // list reads as sections rather than one long flat run.
  static String _providerCategory(String platform, String name) {
    final s = '$platform $name'.toLowerCase();
    if (s.contains('openrouter') ||
        s.contains('hugging') ||
        s.contains('github') ||
        s.contains('tokenmix') ||
        s.contains('vercel')) {
      return 'Aggregators / routers';
    }
    if (s.contains('cloudflare') ||
        s.contains('azure') ||
        s.contains('bedrock') ||
        s.contains('vertex')) {
      return 'Cloud gateways';
    }
    if (s.contains('groq') ||
        s.contains('cerebras') ||
        s.contains('sambanova') ||
        s.contains('nvidia') ||
        s.contains('together') ||
        s.contains('fireworks') ||
        s.contains('hyperbolic') ||
        s.contains('novita') ||
        s.contains('deepinfra') ||
        s.contains('nebius') ||
        s.contains('replicate') ||
        s.contains('featherless') ||
        s.contains('ollama')) {
      return 'Inference / API platforms';
    }
    return 'Frontier & open-weight model labs';
  }

  // Two provider names refer to the same provider if they share a meaningful
  // token (so "Google Gemini" ↔ "Google (Gemini)", "Mistral" ↔ "Mistral AI",
  // "Zhipu AI" ↔ "Z.AI / Zhipu (GLM)").
  static bool _namesMatch(String a, String b) {
    const generic = {
      'the', 'api', 'ai', 'models', 'model', 'workers', 'labs', 'inc', 'nim',
      'gateway', 'router', 'cloud', 'sdk', 'studio', 'platform'
    };
    Set<String> toks(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
        .split(' ')
        .where((t) => t.length > 2 && !generic.contains(t))
        .toSet();
    if (toks(a).intersection(toks(b)).isNotEmpty) return true;
    // Concatenated-vs-spaced names ("HuggingFace Router" ↔ "Hugging Face").
    String core(String s) {
      var j = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      for (final g in generic) {
        j = j.replaceAll(g, '');
      }
      return j;
    }

    final ca = core(a), cb = core(b);
    return ca.length >= 4 &&
        cb.length >= 4 &&
        (ca.contains(cb) || cb.contains(ca));
  }

  /// The Atlas entry whose name EXACTLY matches a provider (case-insensitive).
  /// Used for the paid/not-public hide decision — the fuzzy [_namesMatch]
  /// collapses generic words ("OpenRouter" → core "open") and would wrongly
  /// match paid "OpenAI", hiding a free routable provider.
  AtlasProvider? _atlasExact(String name) {
    final l = name.trim().toLowerCase();
    for (final c in kProviderAtlas) {
      for (final ap in c.providers) {
        if (ap.name.trim().toLowerCase() == l) return ap;
      }
    }
    return null;
  }

  /// The Atlas entry that matches a routable provider (for its status badge).
  /// Exact match first (so "OpenRouter" → the free OpenRouter entry, not the
  /// fuzzy "OpenAI"), then fall back to fuzzy matching.
  AtlasProvider? _atlasFor(String name) {
    final exact = _atlasExact(name);
    if (exact != null) return exact;
    for (final c in kProviderAtlas) {
      for (final ap in c.providers) {
        if (_namesMatch(ap.name, name)) return ap;
      }
    }
    return null;
  }

  bool _matchesQuery(String text) {
    final q = _providerQuery.trim().toLowerCase();
    return q.isEmpty || text.toLowerCase().contains(q);
  }

  /// One unified, categorised list: routable providers (full key + model
  /// management) and the rest of the Atlas (reference + "Get API key"),
  /// grouped under the same families.
  Widget _buildProvidersTab() {
    final scheme = Theme.of(context).colorScheme;

    // Routable backend providers, bucketed into the Atlas families.
    final backendByCat = <String, List<Map<String, dynamic>>>{};
    for (final p in _providers) {
      backendByCat
          .putIfAbsent(
              _providerCategory(
                  p['platform'] as String? ?? '', p['name'] as String? ?? ''),
              () => [])
          .add(p);
    }

    // First build with data: collapse the reference-only families by default.
    if (!_collapseInit && _providers.isNotEmpty) {
      for (final cat in kProviderAtlas) {
        if ((backendByCat[cat.title] ?? []).isEmpty) {
          _collapsedCats.add(cat.title);
        }
      }
      _collapseInit = true;
    }
    // While searching, expand everything so matches are never hidden.
    final searching = _providerQuery.trim().isNotEmpty;

    final children = <Widget>[
      // Search box.
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: TextField(
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: 'Search providers',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (v) => setState(() => _providerQuery = v),
        ),
      ),
    ];

    for (final cat in kProviderAtlas) {
      // Only KEYABLE providers (routable backend catalog), and not the paid /
      // not-public ones — per the cleaned-up provider list.
      final backend = (backendByCat[cat.title] ?? []).where((p) {
        // Hide a routable provider ONLY if its EXACT atlas entry is paid /
        // not-public. (Fuzzy matching collapsed "OpenRouter"→"open"→paid
        // "OpenAI" and wrongly hid it; same for "GitHub Models".)
        final atlas = _atlasExact(p['name'] as String);
        if (atlas != null &&
            (atlas.status == AtlasStatus.paid ||
                atlas.status == AtlasStatus.notPublic)) {
          return false;
        }
        return _matchesQuery('${p['name']} ${p['platform']} ${cat.title}');
      }).toList();

      if (backend.isEmpty) continue;

      final collapsed = !searching && _collapsedCats.contains(cat.title);
      final count = backend.length;
      children.add(
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            _collapsedCats.contains(cat.title)
                ? _collapsedCats.remove(cat.title)
                : _collapsedCats.add(cat.title);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.keyboard_arrow_down,
                      size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 4),
                Text(cat.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        letterSpacing: 0.3,
                        color: scheme.primary)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$count',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ),
              ],
            ),
          ),
        ),
      );
      if (collapsed) continue;
      for (final p in backend) {
        children.add(_ProviderCard(
          provider: p,
          atlas: _atlasFor(p['name'] as String),
          keys: _keysFor(p['platform'] as String),
          onAddKey: _addKey,
          onToggleKey: _toggleKey,
          onDeleteKey: _deleteKey,
          onRefreshModels: _refreshModels,
          onToggleModel: _toggleModel,
          onBulkToggle: _bulkToggle,
          onValidateKey: _validateKey,
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      children: children,
    );
  }

  /// Enable/disable a single catalog model for routing (from a provider card
  /// or the "Show Models" popup). Optimistic: the shared catalog flips first so
  /// the inline list updates instantly, then we reconcile silently (no spinner)
  /// — reverting on failure.
  Future<void> _toggleModel(int modelDbId, bool enabled) async {
    setState(() {
      for (final p in _providers) {
        for (final m in (p['models'] as List<dynamic>? ?? const [])) {
          if (m['id'] == modelDbId) m['enabled'] = enabled;
        }
      }
    });
    try {
      await _api().setFallback(enabled: {modelDbId: enabled});
      await _load(silent: true); // reconcile fallback/counts, no spinner
    } catch (e) {
      _snack('Update failed: $e', error: true);
      await _load(silent: true); // revert to server truth
    }
  }

  /// Enable/disable many models at once (used by the popup's "Enable All").
  /// Optimistic + one API call.
  Future<void> _bulkToggle(Map<int, bool> updates) async {
    if (updates.isEmpty) return;
    setState(() {
      for (final p in _providers) {
        for (final m in (p['models'] as List<dynamic>? ?? const [])) {
          final id = m['id'];
          if (id is int && updates.containsKey(id)) m['enabled'] = updates[id];
        }
      }
    });
    try {
      await _api().setFallback(enabled: updates);
      await _load(silent: true);
    } catch (e) {
      _snack('Update failed: $e', error: true);
      await _load(silent: true);
    }
  }

  Future<void> _addKey(String platform, String key, String label) async {
    if (key.trim().isEmpty) return;
    try {
      await _api().addProviderKey(platform, key.trim(), label: label.trim());
      _snack('Key added to $platform.');
      await _load();
    } catch (e) {
      _snack('Add key failed: $e', error: true);
    }
  }

  Future<void> _toggleKey(int id, bool enabled) async {
    try {
      await _api().setProviderKeyEnabled(id, enabled);
      await _load();
    } catch (e) {
      _snack('Update failed: $e', error: true);
    }
  }

  Future<void> _deleteKey(int id) async {
    try {
      await _api().deleteProviderKey(id);
      _snack('Key removed.');
      await _load();
    } catch (e) {
      _snack('Delete failed: $e', error: true);
    }
  }

  Future<void> _validateKey(int id) async {
    try {
      final status = await _api().validateProviderKey(id);
      _snack(status == 'healthy'
          ? 'Key is healthy ✓'
          : status == 'invalid'
              ? 'Key is invalid — check it on the provider.'
              : 'Could not reach the provider (try again).');
      await _load();
    } catch (e) {
      _snack('Validate failed: $e', error: true);
    }
  }

  Future<void> _refreshModels(String platform) async {
    try {
      final r = await _api().refreshProviderModels(platform);
      _snack('Discovered ${r['discovered']} models, added ${r['added']} new.');
      await _load();
    } catch (e) {
      _snack('Refresh failed: $e', error: true);
    }
  }

  // ---- Fallback tab ----------------------------------------------------
  // Only the *enabled* models form the routing chain — discovered/disabled
  // models (which can be hundreds per provider) are enabled from a provider
  // card, not shown here.
  Widget _buildFallbackTab() {
    final active = _fallback.where((e) => e['enabled'] == true).toList();
    if (active.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No models enabled for routing.\nEnable some from the '
            'Providers & Keys tab.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Active routing chain (${active.length}). Drag to set '
                  'priority (top = tried first); a rate-limited model sinks '
                  'automatically (penalty badge).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            itemCount: active.length,
            onReorder: _reorder,
            itemBuilder: (_, i) {
              final e = active[i];
              return _FallbackRow(
                key: ValueKey(e['model_db_id']),
                entry: e,
                index: i,
                onToggle: (on) => _toggleFallback(e['model_db_id'] as int, on),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    setState(() {
      // Reorder within the enabled subset, then splice that order back into
      // `_fallback` so the enabled slots reflect the new sequence.
      final active = _fallback.where((e) => e['enabled'] == true).toList();
      if (newIndex > oldIndex) newIndex -= 1;
      final item = active.removeAt(oldIndex);
      active.insert(newIndex, item);
      var ai = 0;
      _fallback = _fallback
          .map((e) => e['enabled'] == true ? active[ai++] : e)
          .toList();
    });
    final order = _fallback
        .where((e) => e['enabled'] == true)
        .map((e) => e['model_db_id'] as int)
        .toList(growable: false);
    try {
      await _api().setFallback(order: order);
    } catch (e) {
      _snack('Reorder failed: $e', error: true);
      await _load();
    }
  }

  Future<void> _toggleFallback(int modelDbId, bool enabled) async {
    setState(() {
      for (final e in _fallback) {
        if (e['model_db_id'] == modelDbId) e['enabled'] = enabled;
      }
    });
    try {
      await _api().setFallback(enabled: {modelDbId: enabled});
    } catch (e) {
      _snack('Update failed: $e', error: true);
      await _load();
    }
  }
}

// ===========================================================================
// Routing banner
// ===========================================================================
class _RoutingBanner extends StatelessWidget {
  const _RoutingBanner({required this.auto, required this.onChanged});
  final bool auto;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: auto
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(auto ? Icons.alt_route : Icons.linear_scale,
              color: auto ? scheme.primary : scheme.onSurfaceVariant, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Auto-route across providers',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  auto
                      ? 'Routing to the best available model; falls back on rate limits & outages.'
                      : 'Off — using the single provider configured in Settings.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Switch(value: auto, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ===========================================================================
// Provider card
// ===========================================================================
class _ProviderCard extends StatefulWidget {
  const _ProviderCard({
    required this.provider,
    required this.keys,
    required this.onAddKey,
    required this.onToggleKey,
    required this.onDeleteKey,
    required this.onRefreshModels,
    required this.onToggleModel,
    required this.onBulkToggle,
    required this.onValidateKey,
    this.atlas,
  });

  final Map<String, dynamic> provider;
  /// Matching Atlas entry (free/paid status + note), shown in the header.
  final AtlasProvider? atlas;
  final List<Map<String, dynamic>> keys;
  final void Function(String platform, String key, String label) onAddKey;
  final void Function(int id, bool enabled) onToggleKey;
  final void Function(int id) onDeleteKey;
  final void Function(int id) onValidateKey;
  final void Function(String platform) onRefreshModels;
  final void Function(int modelDbId, bool enabled) onToggleModel;
  final void Function(Map<int, bool> updates) onBulkToggle;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  final _keyCtrl = TextEditingController();
  bool _obscure = true;
  String _modelQuery = '';

  // Inline list shows only the top N (enabled first); the rest live behind
  // the "Show Models" popup.
  static const int _kTopN = 10;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submitKey(String platform) {
    widget.onAddKey(platform, _keyCtrl.text, '');
    _keyCtrl.clear();
  }

  // Where to create an API key, per backend platform id. Falls back to a
  // name match against the Provider Atlas for anything not listed here.
  static const Map<String, String> _kKeyPortals = {
    'openai': 'platform.openai.com/api-keys',
    'google': 'aistudio.google.com/app/apikey',
    'gemini': 'aistudio.google.com/app/apikey',
    'anthropic': 'console.anthropic.com/settings/keys',
    'groq': 'console.groq.com/keys',
    'cerebras': 'cloud.cerebras.ai',
    'sambanova': 'cloud.sambanova.ai',
    'openrouter': 'openrouter.ai/keys',
    'deepseek': 'platform.deepseek.com/api_keys',
    'mistral': 'console.mistral.ai/api-keys',
    'cohere': 'dashboard.cohere.com/api-keys',
    'cloudflare': 'dash.cloudflare.com',
    'together': 'api.together.ai/settings/api-keys',
    'fireworks': 'fireworks.ai/account/api-keys',
    'nvidia': 'build.nvidia.com',
    'huggingface': 'huggingface.co/settings/tokens',
    'hyperbolic': 'app.hyperbolic.xyz/settings',
    'novita': 'novita.ai/settings/key-management',
    'ollama': 'ollama.com/settings/keys',
    'kilo': 'app.kilo.ai/profile',
    'pollinations': 'app.pollination.solutions',
    'llm7': 'token.llm7.io',
    // Zhipu / Z.AI (GLM) — key issued via the Vercel AI Gateway in this setup.
    'zhipu': 'vercel.com/ai-gateway',
    'zhipuai': 'vercel.com/ai-gateway',
    'glm': 'vercel.com/ai-gateway',
    'zai': 'vercel.com/ai-gateway',
    'bigmodel': 'vercel.com/ai-gateway',
    'qwen': 'bailian.console.aliyun.com',
    'xai': 'console.x.ai',
    'moonshot': 'platform.moonshot.ai/console/api-keys',
    'ai21': 'studio.ai21.com/account/api-key',
    'featherless': 'featherless.ai/account/api-keys',
    'vercel': 'vercel.com/ai-gateway',
  };

  String? _portalFor(String platform, String name) {
    final p = platform.toLowerCase();
    if (_kKeyPortals.containsKey(p)) return _kKeyPortals[p];
    final n = name.toLowerCase();
    for (final c in kProviderAtlas) {
      for (final ap in c.providers) {
        if (ap.name.toLowerCase().contains(n) ||
            (n.isNotEmpty && n.contains(ap.name.toLowerCase().split(' ').first))) {
          return ap.url;
        }
      }
    }
    return null;
  }

  Future<void> _openPortal(String url) async {
    try {
      await launchUrl(Uri.parse('https://$url'),
          mode: LaunchMode.externalApplication);
    } catch (_) {/* no-op */}
  }

  static int _byRank(dynamic a, dynamic b) =>
      ((a['intelligence_rank'] ?? 100) as num)
          .compareTo((b['intelligence_rank'] ?? 100) as num);

  void _showAllModels(List<dynamic> models) {
    showDialog<void>(
      context: context,
      builder: (_) => _ModelsDialog(
        providerName: widget.provider['name'] as String,
        models: models,
        onToggleModel: widget.onToggleModel,
        onBulkToggle: widget.onBulkToggle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.provider;
    final platform = p['platform'] as String;
    final models = (p['models'] as List<dynamic>?) ?? const [];
    final counts = (p['keys'] as Map<String, dynamic>?) ?? const {};
    final total = counts['total'] ?? 0;
    final healthy = counts['healthy'] ?? 0;
    final anon = p['allow_anonymous'] == true;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: total > 0
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Text(
            (p['name'] as String).characters.first,
            style: TextStyle(
                color: total > 0 ? scheme.onPrimaryContainer : scheme.onSurface,
                fontWeight: FontWeight.w700),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(p['name'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (widget.atlas != null) ...[
              const SizedBox(width: 8),
              _StatusBadge(status: widget.atlas!.status),
            ],
          ],
        ),
        subtitle: Text(
          '${models.length} models · $total key${total == 1 ? '' : 's'}'
          '${total > 0 ? ' ($healthy healthy)' : ''}'
          '${anon ? ' · anonymous tier' : ''}'
          '${widget.atlas != null && widget.atlas!.note.isNotEmpty ? '  ·  ${widget.atlas!.note}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          // Add-key row: one full-width field with inline show/hide + add.
          // Uses hintText (not a floating labelText) so nothing clips while
          // the ExpansionTile animates open.
          TextField(
            controller: _keyCtrl,
            obscureText: _obscure,
            onSubmitted: (_) => _submitKey(platform),
            decoration: InputDecoration(
              isDense: true,
              hintText: platform == 'cloudflare'
                  ? 'account_id:api_token'
                  : 'Paste API key',
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: scheme.primary, width: 1.4),
              ),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 6, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _obscure ? 'Show' : 'Hide',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                          size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    const SizedBox(width: 2),
                    IconButton.filled(
                      tooltip: 'Add key',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add, size: 18),
                      onPressed: () => _submitKey(platform),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Existing keys.
          for (final k in widget.keys)
            _KeyRow(
              data: k,
              onToggle: (on) => widget.onToggleKey(k['id'] as int, on),
              onDelete: () => widget.onDeleteKey(k['id'] as int),
              onValidate: () => widget.onValidateKey(k['id'] as int),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => widget.onRefreshModels(platform),
                icon: const Icon(Icons.cloud_sync, size: 16),
                label: const Text('Refresh models from provider'),
              ),
              if (_portalFor(platform, p['name'] as String) != null)
                TextButton.icon(
                  onPressed: () =>
                      _openPortal(_portalFor(platform, p['name'] as String)!),
                  icon: const Icon(Icons.vpn_key_outlined, size: 16),
                  label: const Text('Get API key'),
                ),
            ],
          ),
          if (models.isNotEmpty) ..._buildModelList(models, scheme),
        ],
      ),
    );
  }

  /// Inline list: the top [_kTopN] models — enabled first (by rank), padded
  /// with the best disabled ones to fill 10 — plus a "Show Models" button that
  /// opens the full, tabbed, responsive popup. A filter narrows the inline
  /// list when typed.
  List<Widget> _buildModelList(List<dynamic> models, ColorScheme scheme) {
    final q = _modelQuery.trim().toLowerCase();
    final enabledCount = models.where((m) => m['enabled'] == true).length;

    List<dynamic> shown;
    if (q.isEmpty) {
      final enabled = models.where((m) => m['enabled'] == true).toList()
        ..sort(_byRank);
      final disabled = models.where((m) => m['enabled'] != true).toList()
        ..sort(_byRank);
      shown = [...enabled.take(_kTopN)];
      if (shown.length < _kTopN) {
        shown.addAll(disabled.take(_kTopN - shown.length));
      }
    } else {
      shown = models.where((m) {
        final id = '${m['model_id']}'.toLowerCase();
        final name = '${m['display_name']}'.toLowerCase();
        return id.contains(q) || name.contains(q);
      }).take(_kTopN).toList();
    }

    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text('Models ($enabledCount on · ${models.length} total)',
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'filter models',
              ),
              onChanged: (v) => setState(() => _modelQuery = v),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _showAllModels(models),
            icon: const Icon(Icons.grid_view_rounded, size: 16),
            label: const Text('Show Models'),
          ),
        ],
      ),
      const SizedBox(height: 4),
      for (final m in shown)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${m['display_name']}'
                  '${(m['intelligence_rank'] ?? 100) < 100 ? '  ·  #${m['intelligence_rank']}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: m['enabled'] == true ? null : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Switch(
                value: m['enabled'] == true,
                onChanged: (on) => widget.onToggleModel(m['id'] as int, on),
              ),
            ],
          ),
        ),
      if (q.isEmpty && models.length > shown.length)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '+${models.length - shown.length} more — tap “Show Models”.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
    ];
  }
}

// ===========================================================================
// All-models popup — responsive grid with Active / Inactive / All tabs
// ===========================================================================
class _ModelsDialog extends StatefulWidget {
  const _ModelsDialog({
    required this.providerName,
    required this.models,
    required this.onToggleModel,
    required this.onBulkToggle,
  });

  final String providerName;
  final List<dynamic> models;
  final void Function(int modelDbId, bool enabled) onToggleModel;
  final void Function(Map<int, bool> updates) onBulkToggle;

  @override
  State<_ModelsDialog> createState() => _ModelsDialogState();
}

class _ModelsDialogState extends State<_ModelsDialog> {
  String _q = '';
  late final List<Map<String, dynamic>> _models;

  @override
  void initState() {
    super.initState();
    // Local copies so optimistic toggles update the popup immediately even
    // though the parent reloads separately.
    _models = widget.models
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
  }

  List<Map<String, dynamic>> _filtered(String tab) {
    var list = _models;
    if (tab == 'active') {
      list = list.where((m) => m['enabled'] == true).toList();
    } else if (tab == 'inactive') {
      list = list.where((m) => m['enabled'] != true).toList();
    } else {
      list = List.of(list);
    }
    final q = _q.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((m) =>
              '${m['display_name']} ${m['model_id']}'.toLowerCase().contains(q))
          .toList();
    }
    list.sort(_ProviderCardState._byRank);
    return list;
  }

  void _toggle(Map<String, dynamic> m, bool on) {
    setState(() => m['enabled'] = on);
    widget.onToggleModel(m['id'] as int, on);
  }

  void _setAll(bool on) {
    final updates = <int, bool>{};
    setState(() {
      for (final m in _models) {
        final id = m['id'];
        if (id is int) {
          m['enabled'] = on;
          updates[id] = on;
        }
      }
    });
    widget.onBulkToggle(updates);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final activeCount = _models.where((m) => m['enabled'] == true).length;
    final inactiveCount = _models.length - activeCount;

    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      clipBehavior: Clip.antiAlias,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1080,
          maxHeight: size.height * 0.86,
        ),
        child: DefaultTabController(
          length: 3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header — occupies the top rounded corners.
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: scheme.outlineVariant)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: scheme.primaryContainer,
                      child: Text(
                        widget.providerName.characters.first,
                        style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.providerName,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                            '${_models.length} models · $activeCount active',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // Search + bulk actions.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: 'Search ${_models.length} models',
                          filled: true,
                          fillColor: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.4),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (v) => setState(() => _q = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.tonalIcon(
                      onPressed: activeCount < _models.length
                          ? () => _setAll(true)
                          : null,
                      icon: const Icon(Icons.done_all, size: 16),
                      label: const Text('Enable all'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: activeCount > 0 ? () => _setAll(false) : null,
                      icon: const Icon(Icons.remove_done, size: 16),
                      label: const Text('Disable all'),
                    ),
                  ],
                ),
              ),
              // Tabs with live counts.
              TabBar(
                dividerColor: scheme.outlineVariant,
                labelColor: scheme.primary,
                indicatorColor: scheme.primary,
                indicatorSize: TabBarIndicatorSize.label,
                unselectedLabelColor: scheme.onSurfaceVariant,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13.5),
                tabs: [
                  Tab(text: 'Active ($activeCount)'),
                  Tab(text: 'Inactive ($inactiveCount)'),
                  Tab(text: 'All (${_models.length})'),
                ],
              ),
              // Grid — bounded between header & footer, so its scrollbar sits
              // on the straight right edge and is never clipped by a corner.
              Expanded(
                child: TabBarView(
                  children: [
                    _grid(_filtered('active'), scheme),
                    _grid(_filtered('inactive'), scheme),
                    _grid(_filtered('all'), scheme),
                  ],
                ),
              ),
              // Footer — occupies the bottom rounded corners.
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
                decoration: BoxDecoration(
                  border:
                      Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Toggle a model to add or remove it from the routing chain.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grid(List<Map<String, dynamic>> list, ColorScheme scheme) {
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No models here.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      );
    }
    return LayoutBuilder(
      builder: (ctx, c) {
        // Responsive columns by available width.
        final cols = c.maxWidth > 880 ? 3 : (c.maxWidth > 560 ? 2 : 1);
        // The default desktop scrollbar (Material ScrollBehavior) handles the
        // TabBarView pages safely; the header/footer bands keep it off the
        // rounded corners. The right inset keeps it clear of the tiles.
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(20, 14, 14, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisExtent: 104,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: list.length,
          itemBuilder: (_, i) => _tile(list[i], scheme),
        );
      },
    );
  }

  static String _fmtK(num? v) {
    if (v == null || v == 0) return '';
    if (v >= 1000000) {
      final m = v / 1000000;
      return '${m % 1 == 0 ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
    }
    if (v >= 1000) {
      final k = v / 1000;
      return '${k % 1 == 0 ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}K';
    }
    return '$v';
  }

  /// Build the per-model stat list from the backend fields.
  List<String> _statsFor(Map<String, dynamic> m) {
    final stats = <String>[];
    final ctx = m['context_window'] as int?;
    if (ctx != null && ctx > 0) stats.add('${_fmtK(ctx)} ctx');
    final size = (m['size_label'] ?? '').toString();
    if (size.isNotEmpty) stats.add(size);
    final rpd = m['rpd_limit'] as int?;
    final rpm = m['rpm_limit'] as int?;
    if (rpd != null && rpd > 0) {
      stats.add('${_fmtK(rpd)}/day');
    } else if (rpm != null && rpm > 0) {
      stats.add('$rpm/min');
    }
    final tpm = m['tpm_limit'] as int?;
    if (tpm != null && tpm > 0) stats.add('${_fmtK(tpm)} tpm');
    return stats;
  }

  Widget _tile(Map<String, dynamic> m, ColorScheme scheme) {
    final on = m['enabled'] == true;
    final rank = (m['intelligence_rank'] ?? 100) as num;
    final vision = m['supports_vision'] == true;
    final stats = _statsFor(m);

    Widget chip(String text, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: (color ?? scheme.onSurfaceVariant).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: color ?? scheme.onSurfaceVariant)),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: on
            ? scheme.primary.withValues(alpha: 0.08)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: on
              ? scheme.primary.withValues(alpha: 0.4)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text('${m['display_name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: on ? null : scheme.onSurfaceVariant)),
                    ),
                    if (vision) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.visibility_outlined,
                          size: 13, color: scheme.primary),
                    ],
                  ],
                ),
                Text('${m['model_id']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    if (rank < 100) chip('#$rank', color: scheme.primary),
                    for (final s in stats) chip(s),
                    if (stats.isEmpty && rank >= 100)
                      chip('no limits listed'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Switch(value: on, onChanged: (v) => _toggle(m, v)),
        ],
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({
    required this.data,
    required this.onToggle,
    required this.onDelete,
    required this.onValidate,
  });
  final Map<String, dynamic> data;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onValidate;

  Color _statusColor(ColorScheme s) {
    switch (data['status']) {
      case 'healthy':
        return Colors.green;
      case 'invalid':
        return s.error;
      case 'error':
        return Colors.orange;
      default:
        return s.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 10),
            decoration:
                BoxDecoration(color: _statusColor(scheme), shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              '${data['masked']}'
              '${(data['label'] as String?)?.isNotEmpty == true ? '  ·  ${data['label']}' : ''}'
              '  ·  ${data['status']}',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          // Validate now — emphasised when the key isn't healthy.
          if (data['status'] == 'healthy')
            IconButton(
              tooltip: 'Re-validate key',
              icon: Icon(Icons.verified_outlined,
                  size: 18, color: scheme.onSurfaceVariant),
              onPressed: onValidate,
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: OutlinedButton.icon(
                onPressed: onValidate,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.primary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Validate'),
              ),
            ),
          Switch(
            value: data['enabled'] == true,
            onChanged: onToggle,
          ),
          IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Fallback row
// ===========================================================================
class _FallbackRow extends StatelessWidget {
  const _FallbackRow({
    super.key,
    required this.entry,
    required this.index,
    required this.onToggle,
  });
  final Map<String, dynamic> entry;
  final int index;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final penalty = (entry['penalty'] as int?) ?? 0;
    final enabled = entry['enabled'] == true;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: scheme.surfaceContainerHighest,
          child: Text('${index + 1}', style: const TextStyle(fontSize: 12)),
        ),
        title: Text('${entry['display_name']}',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: enabled ? null : scheme.onSurfaceVariant)),
        subtitle: Text('${entry['platform']} · ${entry['model_id']}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (penalty > 0)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('penalty $penalty',
                    style: TextStyle(
                        fontSize: 11, color: scheme.onErrorContainer)),
              ),
            Switch(value: enabled, onChanged: onToggle),
            const SizedBox(width: 4),
            Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Generation defaults (moved here from the old Settings → LLM section)
// ===========================================================================
class _GenerationDefaults extends StatefulWidget {
  const _GenerationDefaults({required this.onSaved});
  final void Function(String message) onSaved;

  @override
  State<_GenerationDefaults> createState() => _GenerationDefaultsState();
}

class _GenerationDefaultsState extends State<_GenerationDefaults> {
  late final TextEditingController _temp;
  late final TextEditingController _maxTokens;
  late final TextEditingController _timeout;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final llm = context.read<AppState>().config.section('llm');
    _temp = TextEditingController(text: '${llm['temperature'] ?? 0.3}');
    _maxTokens = TextEditingController(text: '${llm['max_tokens'] ?? 10000}');
    _timeout = TextEditingController(text: '${llm['timeout_seconds'] ?? 120.0}');
  }

  @override
  void dispose() {
    _temp.dispose();
    _maxTokens.dispose();
    _timeout.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final update = <String, dynamic>{};
    final t = double.tryParse(_temp.text.trim());
    final mt = int.tryParse(_maxTokens.text.trim());
    final to = double.tryParse(_timeout.text.trim());
    if (t != null) update['temperature'] = t;
    if (mt != null) update['max_tokens'] = mt;
    if (to != null) update['timeout_seconds'] = to;
    if (update.isEmpty) return;
    setState(() => _saving = true);
    try {
      final updated = await updateAppConfig(state.baseUrl, {'llm': update});
      if (!mounted) return;
      state.replaceConfig(updated);
      widget.onSaved('Generation defaults saved.');
    } catch (e) {
      if (mounted) widget.onSaved('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Applied to every model the router picks. Per-task model selection '
          '(code / vision / classifier) is automatic under auto-routing.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _numField(_temp, 'temperature', '0.0 – 2.0'),
        const SizedBox(height: 12),
        _numField(_maxTokens, 'max_tokens', 'e.g. 10000'),
        const SizedBox(height: 12),
        _numField(_timeout, 'timeout_seconds', 'e.g. 120'),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save defaults'),
          ),
        ),
      ],
    );
  }

  Widget _numField(TextEditingController c, String label, String hint) =>
      TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      );
}


/// A non-routable Atlas provider shown in the unified Providers & Keys list:
/// status badge + note + "Get API key", styled to sit alongside the routable
/// (expandable) provider cards.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final AtlasStatus status;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: status.color.withValues(alpha: 0.5)),
      ),
      child: Text(status.label,
          style: TextStyle(
              color: status.color, fontSize: 10.5, fontWeight: FontWeight.w700)),
    );
  }
}
