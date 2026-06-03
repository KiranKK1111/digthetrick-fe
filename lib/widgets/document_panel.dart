/// Claude-style document preview panel.
///
/// A right-docked panel that renders the current document (from [AppState])
/// as paged PDF images, with Download (all formats), Refresh, and Close in the
/// header and a floating "Page X / Y" indicator. The pages are rasterized on
/// the backend (PyMuPDF) so there's no native PDF renderer on the client.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../state/app_state.dart';
import 'document_download.dart';

class DocumentPanel extends StatefulWidget {
  const DocumentPanel({super.key});

  @override
  State<DocumentPanel> createState() => _DocumentPanelState();
}

class _DocumentPanelState extends State<DocumentPanel> {
  final ApiService _api = ApiService();
  final ScrollController _scroll = ScrollController();

  List<Uint8List> _pages = [];
  bool _loading = false;
  String? _error;
  int _current = 1;

  // Track what we last rendered so we only re-fetch when the doc changes.
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_pages.isEmpty || !_scroll.hasClients) return;
    // Estimate the current page from scroll offset over total extent.
    final frac = _scroll.position.maxScrollExtent <= 0
        ? 0.0
        : _scroll.offset / _scroll.position.maxScrollExtent;
    final page = (frac * (_pages.length - 1)).round() + 1;
    if (page != _current && page >= 1 && page <= _pages.length) {
      setState(() => _current = page);
    }
  }

  Future<void> _load(String content, String? title, {bool force = false}) async {
    final key = '${title ?? ''}::${content.hashCode}';
    if (!force && key == _loadedFor) return;
    _loadedFor = key;
    setState(() {
      _loading = true;
      _error = null;
      if (force) _pages = [];
    });
    try {
      // Render any ```mermaid``` diagrams to embedded images so they appear in
      // the preview (and the downloaded file matches).
      final prepared = await embedDiagrams(content);
      final res = await _api.previewDocument(content: prepared, title: title);
      if (!mounted) return;
      setState(() {
        _pages = [for (final b64 in res.pages) base64Decode(b64)];
        _loading = false;
        _current = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    // Image mode: render the clicked attachment instead of a paged PDF render.
    if (app.isImagePreview) {
      return _ImagePreview(
        bytes: app.imageBytes!,
        name: app.imageName ?? 'Image',
      );
    }
    final content = app.docContent;
    final title = app.docTitle ?? 'Document';
    if (content == null) return const SizedBox.shrink();

    // Kick off (or refresh) the render after the frame when the doc changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(content, app.docTitle);
    });

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          _header(context, theme, title, content, app),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _body(theme, content, title)),
                if (_pages.isNotEmpty)
                  Positioned(
                    right: 16,
                    bottom: 14,
                    child: _PageBadge(current: _current, total: _pages.length),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, ThemeData theme, String title,
      String content, AppState app) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.article_outlined,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('Document preview · PDF',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          // Direct download in the generated format — no dropdown.
          IconButton(
            tooltip: 'Download ${app.docFormat.toUpperCase()}',
            icon: const Icon(Icons.download_outlined, size: 18),
            onPressed: () => exportAndSave(
              context,
              content: content,
              format: app.docFormat,
              suggestedName: app.docName ?? title,
              title: title,
            ),
          ),
          IconButton(
            tooltip: 'Refresh preview',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => _load(content, app.docTitle, force: true),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => context.read<AppState>().closeDocument(),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, String content, String title) {
    if (_loading && _pages.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  color: theme.colorScheme.error, size: 32),
              const SizedBox(height: 10),
              Text('Could not render the preview.',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: () => _load(content, title, force: true),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    // The paged document: each PNG page on a soft backdrop, like a PDF viewer.
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: ListView.separated(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          itemCount: _pages.length,
          separatorBuilder: (_, __) => const SizedBox(height: 16),
          itemBuilder: (context, i) => DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Image.memory(_pages[i], fit: BoxFit.fitWidth),
          ),
        ),
      ),
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('Page $current / $total',
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onInverseSurface)),
    );
  }
}

/// Right-docked preview for a raw image clicked from a chat attachment.
/// Mirrors the document panel's chrome (header + close + download) but renders
/// the bytes directly, pan/zoomable via [InteractiveViewer] with +/- controls.
class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  final TransformationController _zoomCtrl = TransformationController();
  Size _viewport = Size.zero;
  static const double _kMinZoom = 1.0;
  static const double _kMaxZoom = 8.0;

  @override
  void didUpdateWidget(covariant _ImagePreview old) {
    super.didUpdateWidget(old);
    // A different image opened in the panel → reset the zoom.
    if (old.bytes != widget.bytes) _zoomCtrl.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    super.dispose();
  }

  void _zoomBy(double factor) {
    final current = _zoomCtrl.value.getMaxScaleOnAxis();
    var target = current * factor;
    if (target < _kMinZoom) target = _kMinZoom;
    if (target > _kMaxZoom) target = _kMaxZoom;
    final applied = current == 0 ? 1.0 : target / current;
    if (applied == 1.0) return;
    final cx = _viewport.width / 2;
    final cy = _viewport.height / 2;
    final around = Matrix4.diagonal3Values(applied, applied, 1.0)
      ..setTranslationRaw(cx * (1 - applied), cy * (1 - applied), 0);
    _zoomCtrl.value = around * _zoomCtrl.value;
  }

  void _resetZoom() => _zoomCtrl.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.image_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text('Image preview',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Download image',
                  icon: const Icon(Icons.download_outlined, size: 18),
                  onPressed: () => saveBytes(context,
                      bytes: widget.bytes, filename: widget.name),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => context.read<AppState>().closeDocument(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.4),
              child: LayoutBuilder(builder: (context, c) {
                _viewport = Size(c.maxWidth, c.maxHeight);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _zoomCtrl,
                        minScale: _kMinZoom,
                        maxScale: _kMaxZoom,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Image.memory(
                              widget.bytes,
                              fit: BoxFit.contain,
                              errorBuilder: (ctx, e, st) => Center(
                                child: Text('Could not display this image.',
                                    style: theme.textTheme.bodySmall),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: _PreviewZoomControls(
                        onZoomIn: () => _zoomBy(1.25),
                        onZoomOut: () => _zoomBy(0.8),
                        onReset: _resetZoom,
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

/// Zoom controls for the image/diagram preview panel (bottom-right).
class _PreviewZoomControls extends StatelessWidget {
  const _PreviewZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(icon, size: 18, color: scheme.onSurface),
            ),
          ),
        );
    final divider = Container(
      width: 1,
      height: 20,
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    );
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(Icons.remove, 'Zoom out', onZoomOut),
          divider,
          btn(Icons.add, 'Zoom in', onZoomIn),
          divider,
          btn(Icons.fit_screen_outlined, 'Reset', onReset),
        ],
      ),
    );
  }
}
