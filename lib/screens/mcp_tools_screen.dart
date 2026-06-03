/// MCP tools — list / grant / revoke.
///
/// Architecture.md §"MCP": the user can browse every installed MCP
/// server's tools, see each tool's danger level, and approve or revoke
/// individual tools. The grant persists across restarts (stored under
/// ~/.digthetrick/mcp_permissions.json on the backend).
library;

import 'package:flutter/material.dart';

import '../services/api_service.dart';

class McpToolsScreen extends StatefulWidget {
  const McpToolsScreen({super.key, required this.baseUrl});

  final String baseUrl;

  @override
  State<McpToolsScreen> createState() => _McpToolsScreenState();
}

class _McpToolsScreenState extends State<McpToolsScreen> {
  late final ApiService _api = ApiService(baseUrl: widget.baseUrl);
  List<Map<String, dynamic>>? _tools;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await _api.listMcpTools();
      setState(() => _tools = list);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(Map<String, dynamic> tool) async {
    final name = tool['name'] as String;
    final granted = tool['granted'] as bool? ?? false;
    setState(() => _busy = true);
    try {
      if (granted) {
        await _api.revokeMcpTool(name);
      } else {
        await _api.grantMcpTool(name);
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _dangerColor(String? danger) {
    switch ((danger ?? 'low').toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools (MCP)'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _tools == null
            ? Center(
                child: _error != null
                    ? Text(_error!)
                    : const CircularProgressIndicator(),
              )
            : _tools!.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No MCP tools installed yet. Add servers in config.yaml '
                        'under `mcp.servers`, or via the /api/mcp/servers '
                        'endpoint.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemBuilder: (_, i) {
                      final t = _tools![i];
                      final granted = t['granted'] as bool? ?? false;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _dangerColor(t['danger'] as String?),
                          radius: 6,
                        ),
                        title: Text(t['name'] as String? ?? ''),
                        subtitle: Text(
                          '${t['server'] ?? '?'} — ${t['description'] ?? ''}',
                        ),
                        trailing: Switch(
                          value: granted,
                          onChanged: _busy ? null : (_) => _toggle(t),
                        ),
                      );
                    },
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemCount: _tools!.length,
                  ),
      ),
    );
  }
}
