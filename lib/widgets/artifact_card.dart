/// Multi-artifact response card — Architecture.md §"Multi-artifact".
///
/// Renders a list of [Artifact]s (file name + language + content) as a
/// tabbed surface — one tab per file. The tab header carries:
///   - the filename (clickable to copy)
///   - the language chip
///   - a "Save" button (downloads the bytes on web / saves on desktop)
///
/// The card respects the surrounding layout — it never grows past the
/// parent's max width. Falls back to a single block when there's only
/// one artifact.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'document_download.dart';

class Artifact {
  Artifact({
    required this.filename,
    required this.language,
    required this.content,
  });

  factory Artifact.fromJson(Map<String, dynamic> json) => Artifact(
        filename: json['filename'] as String? ?? 'snippet.txt',
        language: json['language'] as String? ?? 'txt',
        content: json['content'] as String? ?? '',
      );

  final String filename;
  final String language;
  final String content;
}

class ArtifactCard extends StatefulWidget {
  const ArtifactCard({super.key, required this.artifacts});

  final List<Artifact> artifacts;

  @override
  State<ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<ArtifactCard>
    with SingleTickerProviderStateMixin {
  late TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: widget.artifacts.length, vsync: this);
  }

  @override
  void didUpdateWidget(covariant ArtifactCard old) {
    super.didUpdateWidget(old);
    if (old.artifacts.length != widget.artifacts.length) {
      _controller.dispose();
      _controller = TabController(length: widget.artifacts.length, vsync: this);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.artifacts.isEmpty) return const SizedBox.shrink();
    if (widget.artifacts.length == 1) {
      return _ArtifactBody(artifact: widget.artifacts.first);
    }
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            controller: _controller,
            isScrollable: true,
            tabs: [
              for (final a in widget.artifacts) Tab(text: a.filename),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 480),
            child: TabBarView(
              controller: _controller,
              children: [
                for (final a in widget.artifacts) _ArtifactBody(artifact: a),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The artifact filename without its extension — used as the download stem.
String _stem(String filename) {
  final dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.substring(0, dot) : filename;
}

class _ArtifactBody extends StatelessWidget {
  const _ArtifactBody({required this.artifact});

  final Artifact artifact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Chip(
                label: Text(artifact.language),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  artifact.filename,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: artifact.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${artifact.filename} copied')),
                  );
                },
              ),
              // Download this artifact as a document (md/docx/pdf/xlsx/csv/txt).
              DownloadMenuButton(
                content: artifact.content,
                suggestedName: _stem(artifact.filename),
                title: _stem(artifact.filename),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: SelectableText(
                  artifact.content,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
