import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../services/local_storage_service.dart';
import '../models/firestore/fs_conversation.dart';

/// Development / debug screen.
///
/// Provides tools to inspect internal app state and verify data consistency.
class DevScreen extends StatelessWidget {
  const DevScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dev'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user),
              title: const Text('Sanity Check'),
              subtitle: const Text(
                'Compare Firestore conversations with local storage',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _SanityCheckScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Sanity check screen
// ────────────────────────────────────────────────────────────────────────────

/// Result of comparing one conversation between Firestore and local storage.
class _ConversationCheckResult {
  final String conversationId;
  final bool inFirestore;
  final bool inLocal;

  // Firestore data (present when inFirestore == true)
  final List<String>? firestorePeerIds;
  final ConversationState? firestoreState;

  // Local data (present when inLocal == true)
  final List<String>? localPeerIds;
  final int? localKeyBytes;

  const _ConversationCheckResult({
    required this.conversationId,
    required this.inFirestore,
    required this.inLocal,
    this.firestorePeerIds,
    this.firestoreState,
    this.localPeerIds,
    this.localKeyBytes,
  });

  /// True when the conversation exists in both sources and no discrepancy was
  /// found between the data points we compare.
  bool get isConsistent {
    if (!inFirestore || !inLocal) return false;
    // Compare peer lists (order-insensitive)
    if (firestorePeerIds != null && localPeerIds != null) {
      final fsSet = Set<String>.from(firestorePeerIds!);
      final localSet = Set<String>.from(localPeerIds!);
      if (fsSet != localSet) return false;
    }
    return true;
  }

  String get statusLabel {
    if (inFirestore && inLocal) {
      return isConsistent ? 'OK' : 'Mismatch';
    }
    if (inFirestore && !inLocal) return 'Missing locally';
    if (!inFirestore && inLocal) return 'Orphaned locally';
    return 'Unknown';
  }

  Color statusColor(BuildContext context) {
    if (inFirestore && inLocal && isConsistent) return Colors.green;
    if (inFirestore && inLocal && !isConsistent) return Colors.orange;
    return Colors.red;
  }
}

class _SanityCheckScreen extends StatefulWidget {
  const _SanityCheckScreen();

  @override
  State<_SanityCheckScreen> createState() => _SanityCheckScreenState();
}

class _SanityCheckScreenState extends State<_SanityCheckScreen> {
  final AuthService _authService = AuthService();
  final LocalStorageService _localStorage = LocalStorageService();

  bool _isRunning = false;
  String? _errorMessage;
  List<_ConversationCheckResult>? _results;

  Future<void> _runSanityCheck() async {
    setState(() {
      _isRunning = true;
      _errorMessage = null;
      _results = null;
    });

    try {
      final userId = _authService.currentUserId;
      if (userId == null || userId.isEmpty) {
        setState(() {
          _errorMessage = 'Not logged in';
          _isRunning = false;
        });
        return;
      }

      // ── Firestore conversations ───────────────────────────────────────────
      final firestoreService = FirestoreService(localUserId: userId);
      final firestoreConvos = await firestoreService.getUserConversations();
      final firestoreById = {for (final c in firestoreConvos) c.id: c};

      // ── Local conversations ───────────────────────────────────────────────
      final localConvoIds = await _localStorage.listConversations();
      final localById = <String, Map<String, dynamic>?>{};
      final localKeySizes = <String, int>{};
      for (final id in localConvoIds) {
        localById[id] = await _localStorage.readKeyMetadata(id);
        localKeySizes[id] = await _localStorage.getKeySize(id);
      }

      // ── Merge ─────────────────────────────────────────────────────────────
      final allIds = <String>{
        ...firestoreById.keys,
        ...localById.keys,
      };

      final results = <_ConversationCheckResult>[];
      for (final id in allIds) {
        final fsConvo = firestoreById[id];
        final localMeta = localById[id];

        List<String>? localPeerIds;
        if (localMeta != null && localMeta['peerIds'] is List) {
          localPeerIds = List<String>.from(localMeta['peerIds'] as List);
        }

        results.add(_ConversationCheckResult(
          conversationId: id,
          inFirestore: fsConvo != null,
          inLocal: localById.containsKey(id),
          firestorePeerIds: fsConvo?.peerIds,
          firestoreState: fsConvo?.state,
          localPeerIds: localPeerIds,
          localKeyBytes: localKeySizes[id],
        ));
      }

      // Sort: issues first, then OK
      results.sort((a, b) {
        final aOk = a.inFirestore && a.inLocal && a.isConsistent;
        final bOk = b.inFirestore && b.inLocal && b.isConsistent;
        if (aOk == bOk) return a.conversationId.compareTo(b.conversationId);
        return aOk ? 1 : -1;
      });

      setState(() {
        _results = results;
        _isRunning = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sanity Check'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Run check',
            onPressed: _isRunning ? null : _runSanityCheck,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isRunning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Comparing Firestore and local storage…'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _runSanityCheck,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_results == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Press the button to compare Firestore\nconversations with local storage.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _runSanityCheck,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run Sanity Check'),
            ),
          ],
        ),
      );
    }

    if (_results!.isEmpty) {
      return const Center(
        child: Text(
          'No conversations found.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final okCount = _results!
        .where((r) => r.inFirestore && r.inLocal && r.isConsistent)
        .length;
    final total = _results!.length;

    return Column(
      children: [
        // Summary banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: okCount == total
              ? Colors.green.withOpacity(0.12)
              : Colors.orange.withOpacity(0.12),
          child: Row(
            children: [
              Icon(
                okCount == total ? Icons.check_circle : Icons.warning,
                color: okCount == total ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(
                '$okCount / $total conversations consistent',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: okCount == total ? Colors.green[700] : Colors.orange[700],
                ),
              ),
            ],
          ),
        ),
        // Results list
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: _results!.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = _results![index];
              return _ConversationResultTile(result: r);
            },
          ),
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Individual result tile
// ────────────────────────────────────────────────────────────────────────────

class _ConversationResultTile extends StatelessWidget {
  final _ConversationCheckResult result;

  const _ConversationResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.statusColor(context);
    final shortId = result.conversationId.length > 20
        ? '${result.conversationId.substring(0, 20)}…'
        : result.conversationId;

    return ExpansionTile(
      leading: Icon(
        result.inFirestore && result.inLocal && result.isConsistent
            ? Icons.check_circle
            : Icons.warning,
        color: color,
      ),
      title: Text(shortId, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        result.statusLabel,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                label: 'ID',
                value: result.conversationId,
                monospace: true,
              ),
              const SizedBox(height: 4),
              _InfoRow(
                label: 'Firestore',
                value: result.inFirestore ? 'present' : 'absent',
                color: result.inFirestore ? Colors.green : Colors.red,
              ),
              if (result.inFirestore) ...[
                _InfoRow(
                  label: '  state',
                  value: result.firestoreState?.name ?? '—',
                ),
                _InfoRow(
                  label: '  peers',
                  value: result.firestorePeerIds?.join(', ') ?? '—',
                ),
              ],
              const SizedBox(height: 4),
              _InfoRow(
                label: 'Local',
                value: result.inLocal ? 'present' : 'absent',
                color: result.inLocal ? Colors.green : Colors.red,
              ),
              if (result.inLocal) ...[
                _InfoRow(
                  label: '  key size',
                  value: result.localKeyBytes != null
                      ? '${result.localKeyBytes} bytes'
                      : '—',
                ),
                _InfoRow(
                  label: '  peers',
                  value: result.localPeerIds?.join(', ') ?? '—',
                ),
              ],
              if (result.inFirestore && result.inLocal && !result.isConsistent) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning, size: 16, color: Colors.orange),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Peer list mismatch between Firestore and local metadata.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final bool monospace;

  const _InfoRow({
    required this.label,
    required this.value,
    this.color,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }
}
