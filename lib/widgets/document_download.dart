/// Claude-style "Download as…" for assistant answers and artifacts.
///
/// [DownloadMenuButton] shows a format picker (Markdown / Word / PDF / Excel /
/// CSV / Text); selecting one POSTs the content to `/api/documents/export`,
/// gets the generated file bytes back, opens a save dialog, and writes the
/// file. Desktop-first (uses dart:io to write the chosen path).
library;

import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'mermaid_renderer.dart';

/// Replace ```mermaid``` blocks with rendered PNG images (light, print-friendly)
/// so diagrams actually appear inside generated documents. Falls back to the
/// fenced source for any diagram that fails to render.
Future<String> embedDiagrams(String content) async {
  final re = RegExp(r'```mermaid\s*\n(.*?)```', dotAll: true);
  if (!re.hasMatch(content)) return content;
  final buf = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(content)) {
    buf.write(content.substring(last, m.start));
    final src = (m.group(1) ?? '').trim();
    MermaidImage? img;
    try {
      // render() renders the source verbatim first and applies the repair
      // pass only as a fallback, so all diagram types work in documents too.
      img = await MermaidRenderer.instance
          .render(src, dark: false, forDocument: true);
    } catch (_) {
      img = null;
    }
    if (img != null) {
      buf.write('\n![diagram](data:image/png;base64,${base64Encode(img.png)})\n');
    } else {
      buf.write(m.group(0)); // keep the source if it couldn't render
    }
    last = m.end;
  }
  buf.write(content.substring(last));
  return buf.toString();
}

/// (menu label, backend format, icon). Order = menu order.
const List<(String, String, IconData)> kExportFormats = [
  ('Markdown (.md)', 'md', Icons.notes_outlined),
  ('Word (.docx)', 'docx', Icons.description_outlined),
  ('PDF (.pdf)', 'pdf', Icons.picture_as_pdf_outlined),
  ('Excel (.xlsx)', 'xlsx', Icons.table_chart_outlined),
  ('CSV (.csv)', 'csv', Icons.grid_on_outlined),
  ('Text (.txt)', 'txt', Icons.text_snippet_outlined),
];

/// Generate `content` as `format`, prompt for a location, and save it.
Future<void> exportAndSave(
  BuildContext context, {
  required String content,
  required String format,
  String? suggestedName,
  String? title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final stem = (suggestedName == null || suggestedName.trim().isEmpty)
      ? 'document'
      : suggestedName.trim();
  final filename = '$stem.$format';
  try {
    final prepared = await embedDiagrams(content);
    final bytes = await ApiService().exportDocument(
      content: prepared,
      format: format,
      filename: stem,
      title: title,
    );
    // Desktop: get a target path from the OS dialog, then write the bytes.
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save document',
      fileName: filename,
    );
    if (path == null) return; // user cancelled
    await File(path).writeAsBytes(bytes, flush: true);
    messenger.showSnackBar(
      SnackBar(content: Text('Saved ${path.split(RegExp(r"[\\/]")).last}')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
  }
}

/// Prompt for a location and write raw [bytes] there. Used for already-
/// generated binaries (e.g. a diagram PNG) that don't go through the export
/// endpoint.
Future<void> saveBytes(
  BuildContext context, {
  required List<int> bytes,
  required String filename,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save',
      fileName: filename,
    );
    if (path == null) return; // cancelled
    await File(path).writeAsBytes(bytes, flush: true);
    messenger.showSnackBar(
      SnackBar(content: Text('Saved ${path.split(RegExp(r"[\\/]")).last}')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
  }
}

/// A download icon that opens the format picker. Drop it into any action row.
class DownloadMenuButton extends StatelessWidget {
  const DownloadMenuButton({
    super.key,
    required this.content,
    this.suggestedName,
    this.title,
    this.tooltip = 'Download',
    this.iconSize = 18,
    this.color,
  });

  final String content;
  final String? suggestedName;
  final String? title;
  final String tooltip;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = content.trim().isNotEmpty;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.download_outlined, size: iconSize, color: color),
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text('Download as', style: TextStyle(fontSize: 12)),
        ),
        for (final f in kExportFormats)
          PopupMenuItem<String>(
            value: f.$2,
            child: Row(
              children: [
                Icon(f.$3, size: 18),
                const SizedBox(width: 10),
                Text(f.$1),
              ],
            ),
          ),
      ],
      onSelected: (fmt) => exportAndSave(
        context,
        content: content,
        format: fmt,
        suggestedName: suggestedName,
        title: title,
      ),
    );
  }
}
