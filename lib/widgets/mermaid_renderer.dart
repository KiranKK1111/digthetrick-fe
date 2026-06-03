/// Mermaid diagram rendering — ONE shared off-screen webview for the whole app.
///
/// Why: a webview-per-diagram meant a 3.3 MB mermaid.js parse + a live WebView2
/// instance for every diagram, re-rendering on every scroll. Instead, a single
/// hidden [MermaidRenderHost] webview (mounted once by the root shell) loads
/// mermaid.js ONCE and rasterizes each diagram to a 2× PNG on demand. Results
/// are cached, so a diagram renders once and is then a cheap [Image] — no live
/// webviews in the chat, no scroll flicker, instant PNG download.
///
/// Every Mermaid diagram type (flowchart, sequence, class, state, ER, gantt,
/// pie, journey, gitGraph, mindmap, timeline, …) goes through the same path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// The leading diagram keyword (lowercased), e.g. "flowchart", "graph",
/// "classdiagram", "sequencediagram". Skips blank lines, `%%` comments, and
/// `%%{init}%%` directives.
String mermaidKind(String source) {
  for (final line in source.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('%%')) continue;
    final m = RegExp(r'^([A-Za-z][A-Za-z0-9-]*)').firstMatch(t);
    return (m?.group(1) ?? '').toLowerCase();
  }
  return '';
}

/// REPAIR pass for common model mistakes — applied ONLY as a fallback after the
/// raw source fails to render, so a correctly-written diagram is never altered.
///
/// Scoped to FLOWCHARTS only. The #1 flowchart failure is unquoted special
/// characters in node/edge labels — especially parentheses, e.g. `A[Foo (bar)]`
/// — which mermaid rejects; we wrap those labels in quotes (`A["Foo (bar)"]`).
/// Other diagram types (class, state, er, sequence, gantt, …) use `[]`/`{}`/`|`
/// with DIFFERENT meaning (class/method bodies, etc.), so quoting there would
/// CORRUPT them — for those we return the source unchanged.
String sanitizeMermaid(String source) {
  final kind = mermaidKind(source);
  if (kind != 'flowchart' && kind != 'graph') {
    return source; // never touch non-flowchart syntaxes
  }

  // Quote a node/edge label unless it's already quoted. ANY character beyond
  // letters/digits/space/`_`-`,`.` is a parser risk in mermaid (parentheses,
  // `@`, `:`, `<`, `>`, `#`, `/`, `&`, `=`, `;`, `'`, …), so we quote on the
  // first such character. Safe because this only runs as a fallback AFTER the
  // verbatim source has already failed to render.
  final risky = RegExp(r'[^A-Za-z0-9 _.,\-]');
  String quote(String body) {
    final t = body.trim();
    if (t.isEmpty) return body;
    if (t.startsWith('"') && t.endsWith('"')) return body; // already quoted
    if (!risky.hasMatch(t)) return body; // nothing to escape
    // Mermaid renders `#quot;`/`#35;` HTML entities inside quoted strings.
    final esc = t.replaceAll('"', '#quot;').replaceAll('#', '#35;');
    return '"$esc"';
  }

  var s = source;
  // Normalise HTML line breaks the model sometimes emits.
  s = s.replaceAll(RegExp(r'<br\s*>'), '<br/>');
  // Node-shape labels, longest delimiters first so nested ones match correctly:
  //   [[subroutine]]  [(database)]  ([stadium])  ((circle))  {{hexagon}}
  //   [rect]  {rhombus}  |edge label|
  s = s.replaceAllMapped(
      RegExp(r'\[\[([^\[\]\n]+)\]\]'), (m) => '[[${quote(m[1]!)}]]');
  s = s.replaceAllMapped(
      RegExp(r'\[\(([^\n]+?)\)\]'), (m) => '[(${quote(m[1]!)})]');
  s = s.replaceAllMapped(
      RegExp(r'\(\[([^\n]+?)\]\)'), (m) => '([${quote(m[1]!)}])');
  s = s.replaceAllMapped(
      RegExp(r'\(\(([^()\n]+)\)\)'), (m) => '((${quote(m[1]!)}))');
  s = s.replaceAllMapped(
      RegExp(r'\{\{([^{}\n]+)\}\}'), (m) => '{{${quote(m[1]!)}}}');
  // Plain rectangle [label] — skip the already-handled [[…]] / [(…)] / ([…]).
  s = s.replaceAllMapped(
      RegExp(r'(?<![\[(])\[([^\[\]\n]+)\](?![\])])'),
      (m) => '[${quote(m[1]!)}]');
  // {diamond}
  s = s.replaceAllMapped(
      RegExp(r'(?<!\{)\{([^{}\n]+)\}(?!\})'), (m) => '{${quote(m[1]!)}}');
  // |edge label|
  s = s.replaceAllMapped(
      RegExp(r'\|([^|\n]+)\|'), (m) => '|${quote(m[1]!)}|');
  // subgraph titles with spaces/specials need quoting too.
  s = s.replaceAllMapped(
      RegExp(r'^(\s*subgraph\s+)(?!")([^\n\[]+?)\s*$', multiLine: true),
      (m) => '${m[1]}${quote(m[2]!)}');
  return s;
}

/// A rasterized diagram: PNG bytes + the SVG's CSS-pixel size (pre-scale).
class MermaidImage {
  const MermaidImage(this.png, this.width, this.height);
  final Uint8List png;
  final double width;
  final double height;
}

/// Singleton that drives the shared off-screen webview. [MermaidRenderHost]
/// hands it the controller; [MermaidBlock] calls [render].
class MermaidRenderer {
  MermaidRenderer._();
  static final MermaidRenderer instance = MermaidRenderer._();

  InAppWebViewController? _controller;
  final Completer<void> _ready = Completer<void>();
  final Map<String, Completer<MermaidImage?>> _pending = {};
  // Insertion-ordered (Dart Maps preserve order) → simple FIFO eviction once
  // the cached PNGs exceed the byte budget, so a long session with many unique
  // diagrams can't grow memory without bound.
  final Map<String, MermaidImage> _cache = {};
  static const int _maxCacheBytes = 48 * 1024 * 1024; // ~48 MB of PNGs
  int _cacheBytes = 0;
  Future<void> _queue = Future.value();
  int _seq = 0;

  void _cachePut(String key, MermaidImage img) {
    if (_cache.containsKey(key)) return;
    _cache[key] = img;
    _cacheBytes += img.png.lengthInBytes;
    while (_cacheBytes > _maxCacheBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      final removed = _cache.remove(oldest);
      if (removed != null) _cacheBytes -= removed.png.lengthInBytes;
    }
  }

  bool get isReady => _ready.isCompleted;

  String _key(String source, bool dark) => '${dark ? 'd' : 'l'}|$source';

  /// Synchronous cache peek — lets a rebuild show the image with no spinner.
  MermaidImage? cached(String source, {required bool dark}) =>
      _cache[_key(source, dark)];

  void attachController(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'mermaidResult',
      callback: (args) {
        final data = (args.isNotEmpty ? args.first : null);
        if (data is! Map) return;
        final id = data['id']?.toString();
        final comp = id == null ? null : _pending.remove(id);
        if (comp == null || comp.isCompleted) return;
        if (data['ok'] == true && data['png'] is String) {
          final png = data['png'] as String;
          final comma = png.indexOf(',');
          if (comma < 0) {
            comp.complete(null);
            return;
          }
          comp.complete(MermaidImage(
            base64Decode(png.substring(comma + 1)),
            ((data['w'] as num?) ?? 0).toDouble(),
            ((data['h'] as num?) ?? 0).toDouble(),
          ));
        } else {
          comp.complete(null);
        }
      },
    );
  }

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Render [source] to a PNG (cached). `null` on failure / not-ready timeout.
  /// [forDocument] renders a print-friendly version (light theme, WHITE
  /// background, default mermaid colours) for embedding in generated documents.
  Future<MermaidImage?> render(
    String source, {
    required bool dark,
    bool forDocument = false,
  }) {
    final key = forDocument ? 'doc|$source' : _key(source, dark);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);

    final result = Completer<MermaidImage?>();
    // Serialize renders — mermaid keeps global state during a render pass.
    _queue = _queue.then((_) async {
      // Try the source EXACTLY as written first — a valid diagram of ANY type
      // must never be altered. Only if that fails do we apply the flowchart
      // repair pass and retry, so sanitization can fix malformed diagrams
      // without ever breaking correct ones.
      var img = await _renderOnce(source, dark: dark, forDocument: forDocument);
      if (img == null) {
        final repaired = sanitizeMermaid(source);
        if (repaired != source) {
          img = await _renderOnce(repaired, dark: dark, forDocument: forDocument);
        }
      }
      if (img != null) _cachePut(key, img); // cache under the original key
      if (!result.isCompleted) result.complete(img);
    }).catchError((_) {
      if (!result.isCompleted) result.complete(null);
    });
    return result.future;
  }

  Future<MermaidImage?> _renderOnce(
    String source, {
    required bool dark,
    bool forDocument = false,
  }) async {
    await _ready.future;
    final c = _controller;
    if (c == null) return null;
    final id = 'r${_seq++}';
    final comp = Completer<MermaidImage?>();
    _pending[id] = comp;
    final theme = forDocument ? 'default' : (dark ? 'dark' : 'default');
    // Only flowcharts get the colorful-palette recolor; every other diagram
    // type keeps mermaid's native (readable) theme colours.
    final kind = mermaidKind(source);
    final recolor = !forDocument && (kind == 'flowchart' || kind == 'graph');
    final js = 'window.__mermaidRender(${jsonEncode(id)}, '
        '${jsonEncode(source)}, ${jsonEncode(theme)}, $forDocument, $recolor);';
    try {
      await c.evaluateJavascript(source: js);
    } catch (_) {
      _pending.remove(id);
      return null;
    }
    return comp.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      return null;
    });
  }
}

/// The JS render entry point, injected once after mermaid.js loads. Renders the
/// source to an SVG, recolours the nodes (themed palette + light labels),
/// rasterizes onto a 2× TRANSPARENT canvas, and reports the PNG back over the
/// `mermaidResult` handler. `htmlLabels:false` keeps labels as SVG <text> so the
/// canvas isn't blank (foreignObject draws empty).
const String _renderFnJs = r'''
window.__mermaidRender = async function(reqId, src, theme, forDoc, recolor){
  function done(ok, png, w, h, err){
    window.flutter_inappwebview.callHandler('mermaidResult',
      {id:reqId, ok:ok, png:png||'', w:w||0, h:h||0, err:err||''});
  }
  try{
    if(typeof mermaid === 'undefined'){ done(false,'',0,0,'mermaid missing'); return; }
    mermaid.initialize({ startOnLoad:false, theme:theme, securityLevel:'loose',
      flowchart:{ useMaxWidth:false, htmlLabels:false },
      class:{ htmlLabels:false }, er:{ useMaxWidth:false },
      sequence:{ useMaxWidth:false } });
    var gid = 'mz' + (window.__c=(window.__c||0)+1);
    var out = await mermaid.render(gid, src);
    var div = document.createElement('div');
    div.style.position='absolute'; div.style.left='-99999px'; div.style.top='0';
    div.innerHTML = out.svg;
    document.body.appendChild(div);
    var el = div.querySelector('svg');
    if(!el){ div.remove(); done(false,'',0,0,'no svg'); return; }
    var rect = el.getBoundingClientRect();
    var w = Math.max(1, Math.ceil(rect.width))  || 800;
    var h = Math.max(1, Math.ceil(rect.height)) || 600;
    el.setAttribute('width', w); el.setAttribute('height', h);
    el.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    // Colorful, theme-aligned nodes: cycle a palette across the boxes and make
    // labels light. Edges/arrows keep the theme's colour. The PNG background is
    // transparent (see below) so it blends into the dark message card.
    // For the app's DARK card: cycle a palette across nodes + white labels.
    // For DOCUMENTS: leave mermaid's default light-theme colours (dark text on
    // a light fill) so the diagram reads on a white page.
    if (recolor) try{
      var palette = ['#7C5CFF','#22C55E','#3B82F6','#F59E0B','#EC4899',
        '#06B6D4','#A855F7','#EF4444','#14B8A6','#F97316'];
      var nodes = el.querySelectorAll('g.node');
      for (var i=0;i<nodes.length;i++){
        var col = palette[i % palette.length];
        var shapes = nodes[i].querySelectorAll('rect,polygon,circle,ellipse,path');
        for (var j=0;j<shapes.length;j++){
          shapes[j].setAttribute('fill', col); shapes[j].style.fill = col;
          shapes[j].setAttribute('stroke', 'rgba(255,255,255,0.35)');
          shapes[j].style.stroke = 'rgba(255,255,255,0.35)';
          // Rounded corners on the box shapes.
          if (shapes[j].tagName && shapes[j].tagName.toLowerCase() === 'rect'){
            shapes[j].setAttribute('rx', '8'); shapes[j].setAttribute('ry', '8');
          }
        }
        var labels = nodes[i].querySelectorAll('text,tspan,.nodeLabel');
        for (var k=0;k<labels.length;k++){
          labels[k].setAttribute('fill', '#FFFFFF'); labels[k].style.fill = '#FFFFFF';
        }
      }
    }catch(e){}
    var xml = new XMLSerializer().serializeToString(el);
    var svg64 = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(xml)));
    var img = new Image();
    img.onload = function(){
      try{
        // 3× raster so the diagram stays crisp when displayed larger.
        var scale = 3;
        var canvas = document.createElement('canvas');
        canvas.width = w*scale; canvas.height = h*scale;
        var ctx = canvas.getContext('2d');
        ctx.setTransform(scale,0,0,scale,0,0);
        // White background for documents; transparent for the themed card.
        if (forDoc){ ctx.fillStyle='#ffffff'; ctx.fillRect(0,0,w,h); }
        else { ctx.clearRect(0,0,w,h); }
        ctx.drawImage(img,0,0,w,h);
        var png = canvas.toDataURL('image/png');
        div.remove();
        done(true, png, w, h);
      }catch(e){ div.remove(); done(false,'',0,0,String(e)); }
    };
    img.onerror = function(){ div.remove(); done(false,'',0,0,'img load'); };
    img.src = svg64;
  }catch(e){ done(false,'',0,0,String(e)); }
};
''';

const String _hostHtml = '''
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:#fff;}</style></head>
<body></body></html>
''';

/// The one hidden webview. Mount once in the app shell (root_shell). It's laid
/// out off-screen (NOT Offstage) so its canvas/measurement actually run.
class MermaidRenderHost extends StatelessWidget {
  const MermaidRenderHost({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: -20000,
      top: 0,
      width: 1600,
      height: 1200,
      child: IgnorePointer(
        child: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: _hostHtml,
            mimeType: 'text/html',
            encoding: 'utf-8',
          ),
          initialSettings: InAppWebViewSettings(
            transparentBackground: false,
            supportZoom: false,
          ),
          onWebViewCreated: MermaidRenderer.instance.attachController,
          onLoadStop: (controller, url) async {
            try {
              await controller.injectJavascriptFileFromAsset(
                assetFilePath: 'assets/mermaid/mermaid.min.js',
              );
              await controller.evaluateJavascript(source: _renderFnJs);
            } finally {
              MermaidRenderer.instance.markReady();
            }
          },
        ),
      ),
    );
  }
}

/// One diagram. Renders via the shared [MermaidRenderer] to a cached image and
/// shows it with a Diagram⇄Source toggle, Copy, and Download-PNG toolbar.
class MermaidBlock extends StatefulWidget {
  const MermaidBlock({super.key, required this.source, this.kind = 'mermaid'});
  final String source;
  final String kind;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  MermaidImage? _image;
  bool _loading = true;
  bool _failed = false;
  bool _showSource = false; // Code view toggle (</> button)
  String? _renderedFor; // 'source|brightness' we last rendered

  // Stable identity so this card can tell when IT is the diagram currently
  // open in the preview panel (and collapse itself while it is).
  final Object _ownerId = Object();

  // In-card zoom. The diagram is kept WITHIN the card width (so its sides are
  // never clipped) and zoom grows it taller; when taller than the viewport you
  // scroll vertically (drag / wheel, no scrollbar). The chat list freezes while
  // the cursor is over the diagram so that vertical scroll moves the diagram.
  double _zoom = 1.0;
  static const double _kMinZoom = 1.0; // fit the whole diagram
  static const double _kMaxZoom = 4.0;
  final ScrollController _vScroll = ScrollController();
  AppState? _app;

  @override
  void dispose() {
    _app?.chatScrollLocked.value = false;
    _vScroll.dispose();
    super.dispose();
  }

  void _lockChat(bool v) {
    _app ??= context.read<AppState>();
    _app!.chatScrollLocked.value = v;
  }

  void _zoomBy(double factor) {
    final target = (_zoom * factor).clamp(_kMinZoom, _kMaxZoom);
    if (target == _zoom) return;
    setState(() => _zoom = target);
  }

  void _resetZoom() {
    if (_zoom == 1.0) return;
    setState(() => _zoom = 1.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of() is available here; re-render if the source or theme changed.
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Pass the source as-written. The renderer renders it verbatim first and
    // only applies the (flowchart-scoped) repair pass as a fallback, so every
    // diagram type renders and a correct diagram is never mangled.
    final src = widget.source;
    final key = '$src|$dark';
    if (key != _renderedFor) {
      _renderedFor = key;
      // Already rendered before (e.g. a streaming rebuild)? Show it with no
      // spinner flicker; otherwise render asynchronously.
      final hit = MermaidRenderer.instance.cached(src, dark: dark);
      if (hit != null) {
        _image = hit;
        _loading = false;
        _failed = false;
      } else {
        _start(src, dark);
      }
    }
  }

  Future<void> _start(String src, bool dark) async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final img = await MermaidRenderer.instance.render(src, dark: dark);
    if (!mounted) return;
    _resetZoom(); // a fresh diagram starts at 1×
    setState(() {
      _image = img;
      _loading = false;
      _failed = img == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.kind != 'mermaid') {
      return _SourceCard(source: widget.source, kind: widget.kind);
    }

    // While THIS diagram is the one open in the preview panel, collapse the
    // in-chat card to a slim "opened in preview" placeholder (the diagram lives
    // only in the preview, with all its controls). Closing the preview restores
    // it inline.
    final app = context.watch<AppState>();
    if (app.isImagePreview && app.imageOwnerId == _ownerId) {
      return _ExpandedPlaceholder(
        onCollapse: () => context.read<AppState>().closeDocument(),
      );
    }

    // A full-width themed card with a ChatGPT-style header toolbar over the
    // rendered diagram (centered, decent size), the source, or an error.
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolbar(theme),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: _body(theme),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final canAct = _image != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
        children: [
          Icon(Icons.account_tree_outlined,
              size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('Mermaid',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          _ToolbarIcon(
            icon: Icons.download_outlined,
            tooltip: 'Download PNG',
            onTap: canAct ? _download : null,
          ),
          _ToolbarIcon(
            icon: Icons.code,
            tooltip: _showSource ? 'Show diagram' : 'Show source',
            active: _showSource,
            onTap: () => setState(() => _showSource = !_showSource),
          ),
          _ToolbarIcon(
            icon: Icons.play_arrow_rounded,
            tooltip: 'Re-render',
            onTap: () {
              setState(() => _showSource = false);
              final dark = Theme.of(context).brightness == Brightness.dark;
              _start(widget.source, dark);
            },
          ),
          _ToolbarIcon(
            icon: Icons.open_in_full,
            tooltip: 'Expand',
            onTap: canAct ? _expand : null,
          ),
        ],
      ),
      ),
    );
  }

  Future<void> _download() async {
    final img = _image;
    if (img == null) return;
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save diagram',
        fileName: 'diagram.png',
      );
      if (path == null) return;
      await File(path).writeAsBytes(img.png, flush: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${path.split(RegExp(r"[\\/]")).last}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  // Expand → render the diagram into the right-side preview panel (the same
  // docked panel that shows PDFs and images), full-size + pan/zoom. Tagged with
  // [_ownerId] so this card knows to collapse while it's the one on show.
  void _expand() {
    final img = _image;
    if (img == null) return;
    context
        .read<AppState>()
        .openImage(bytes: img.png, name: 'Diagram', ownerId: _ownerId);
  }

  Widget _body(ThemeData theme) {
    if (_showSource) {
      return _SourceView(source: widget.source, theme: theme);
    }
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_failed || _image == null) {
      return _ErrorView(
        source: widget.source,
        theme: theme,
        onRetry: () {
          final dark = Theme.of(context).brightness == Brightness.dark;
          _start(widget.source, dark);
        },
        onShowSource: () => setState(() => _showSource = true),
      );
    }
    // Keep the diagram WITHIN the card width (never clipped on the sides) and
    // let zoom grow it taller. When it's taller than the viewport you scroll
    // vertically by dragging / wheel (no scrollbar). The chat freezes while the
    // cursor is over the diagram so that scroll moves the diagram, not the chat.
    final natW = _image!.width > 0 ? _image!.width : 360.0;
    final natH = _image!.height > 0 ? _image!.height : 360.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = (constraints.maxWidth.isFinite && constraints.maxWidth > 0)
            ? constraints.maxWidth
            : 720.0;
        // The diagram's max on-screen width (never exceeds the card).
        var cardW = natW * 2.4;
        if (cardW > avail) cardW = avail;
        if (cardW > 560.0) cardW = 560.0;
        const maxViewportH = 520.0;
        // z=1 fits the whole diagram (within cardW × maxViewportH); higher zoom
        // scales it up, but width is capped at cardW so the sides never clip.
        var base = cardW / natW;
        if (maxViewportH / natH < base) base = maxViewportH / natH;
        final maxScale = cardW / natW; // width == cardW
        var scale = base * _zoom;
        if (scale > maxScale) scale = maxScale;
        final dispW = natW * scale;
        final dispH = natH * scale;
        final viewportH = dispH < maxViewportH ? dispH : maxViewportH;

        // Mouse wheel over the diagram ZOOMS it (scroll up = in, down = out).
        // Registering with the resolver consumes the scroll so neither the
        // diagram nor the chat scrolls from the wheel. Drag still pans/scrolls.
        final image = Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver
                  .register(signal, (e) {
                final dy = (e as PointerScrollEvent).scrollDelta.dy;
                _zoomBy(dy < 0 ? 1.1 : 0.9);
              });
            }
          },
          child: SizedBox(
            width: dispW,
            height: dispH,
            child: Image.memory(
              _image!.png,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        );

        // Vertically scrollable (no scrollbar) when taller than the viewport.
        // dragDevices includes the mouse so click-and-drag pans the diagram
        // (Flutter omits mouse from drag-scroll on desktop by default).
        final Widget viewer = dispH > viewportH
            ? SizedBox(
                width: cardW,
                height: viewportH,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                    dragDevices: const {
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.touch,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: SingleChildScrollView(
                    controller: _vScroll,
                    primary: false,
                    child: Center(child: image),
                  ),
                ),
              )
            : SizedBox(width: cardW, height: dispH, child: Center(child: image));

        return Stack(
          children: [
            Center(
              child: MouseRegion(
                onEnter: (_) => _lockChat(true),
                onExit: (_) => _lockChat(false),
                child: viewer,
              ),
            ),
            Positioned(
              right: 4,
              bottom: 4,
              child: _ZoomControls(
                onZoomIn: () => _zoomBy(1.25),
                onZoomOut: () => _zoomBy(0.8),
                onReset: _resetZoom,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A single small toolbar icon for the diagram header.
class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onTap == null
        ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
        : active
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

/// Slim placeholder shown in chat while the diagram is open in the preview
/// panel — keeps the message context without duplicating the diagram.
class _ExpandedPlaceholder extends StatelessWidget {
  const _ExpandedPlaceholder({required this.onCollapse});
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Diagram opened in preview',
              style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500),
            ),
          ),
          TextButton.icon(
            onPressed: onCollapse,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: scheme.onSurfaceVariant,
            ),
            icon: const Icon(Icons.close_fullscreen, size: 15),
            label: const Text('Show here', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

/// Zoom in / out (+ reset) controls pinned to the diagram's bottom-right.
class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
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
              padding: const EdgeInsets.all(6),
              child: Icon(icon, size: 18, color: scheme.onSurface),
            ),
          ),
        );
    final divider = Container(
      width: 1,
      height: 18,
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    );
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
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

/// The mermaid source shown when the </> Code button is toggled on.
class _SourceView extends StatelessWidget {
  const _SourceView({required this.source, required this.theme});
  final String source;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        source,
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 12.5, height: 1.45),
      ),
    );
  }
}

/// Shown when a diagram can't be parsed: a clear message, the source, and a
/// Retry. No more "copy from the ⋯ menu" dead-end.
class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.source,
    required this.theme,
    required this.onRetry,
    required this.onShowSource,
  });
  final String source;
  final ThemeData theme;
  final VoidCallback onRetry;
  final VoidCallback onShowSource;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "This diagram couldn't be rendered. You can view the source or retry.",
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: onShowSource,
              icon: const Icon(Icons.code, size: 16),
              label: const Text('View source'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Fallback for non-mermaid custom-viz kinds: a copyable source card.
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source, required this.kind});
  final String source;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.scatter_plot_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Visualization ($kind)',
                    style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy source',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: source));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Source copied')),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                source,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
