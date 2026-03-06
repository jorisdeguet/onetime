import 'package:flutter/material.dart';
import 'package:onetime/models/firestore/fs_conversation.dart';
import 'package:onetime/models/firestore/fs_message.dart';
import 'package:onetime/services/auth_service.dart';
import 'package:onetime/services/format_service.dart';
import 'package:onetime/services/local_storage_service.dart';
import 'package:onetime/services/message_service.dart';
import 'package:onetime/services/message_storage.dart';
import 'package:onetime/services/pseudo_service.dart';

import 'conversation_detail_screen.dart';

/// A search result entry combining a message with its conversation context.
class _SearchResult {
  final LocalMessage message;
  final String conversationId;
  final String conversationDisplayName;
  final List<String> peerIds;

  const _SearchResult({
    required this.message,
    required this.conversationId,
    required this.conversationDisplayName,
    required this.peerIds,
  });
}

/// Screen for searching messages.
///
/// When [conversation] is provided, searches only within that conversation.
/// When [conversation] is null, searches across all locally stored conversations.
class MessageSearchScreen extends StatefulWidget {
  /// If provided, limits the search to this conversation.
  final Conversation? conversation;

  const MessageSearchScreen({super.key, this.conversation});

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final MessageStorage _messageStorage = MessageStorage();
  final LocalStorageService _localStorage = LocalStorageService();
  final PseudoService _pseudoService = PseudoService();
  final AuthService _authService = AuthService();

  List<_SearchResult> _results = [];
  bool _isLoading = false;
  String _lastQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (trimmed == _lastQuery) return;
    _lastQuery = trimmed;

    if (trimmed.isEmpty) {
      setState(() {
        _results = [];
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final results = await _performSearch(trimmed.toLowerCase());
      if (mounted && trimmed == _lastQuery) {
        setState(() {
          _results = results;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<List<_SearchResult>> _performSearch(String queryLower) async {
    final results = <_SearchResult>[];

    if (widget.conversation != null) {
      // Search within a single conversation
      await _searchConversation(
        conversationId: widget.conversation!.id,
        queryLower: queryLower,
        results: results,
        displayName: _getConversationDisplayName(widget.conversation!),
        peerIds: widget.conversation!.peerIds,
      );
    } else {
      // Search across all locally stored conversations
      final conversationIds = await _localStorage.listConversations();
      for (final convId in conversationIds) {
        final (displayName, peerIds) = await _resolveConversationInfo(convId);
        await _searchConversation(
          conversationId: convId,
          queryLower: queryLower,
          results: results,
          displayName: displayName,
          peerIds: peerIds,
        );
        // Abort if query changed while we were searching
        if (queryLower != _lastQuery.toLowerCase()) break;
      }
    }

    // Sort by most recent first
    results.sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    return results;
  }

  Future<void> _searchConversation({
    required String conversationId,
    required String queryLower,
    required List<_SearchResult> results,
    required String displayName,
    required List<String> peerIds,
  }) async {
    final messages = await _messageStorage.getConversationMessages(conversationId);
    for (final message in messages) {
      // Only search text messages; skip pseudo-exchange messages
      if (message.contentType != MessageContentType.text) continue;
      final text = message.textContent;
      if (text == null || text.isEmpty) continue;
      if (MessageService.isPseudoMessage(text)) continue;

      if (text.toLowerCase().contains(queryLower)) {
        results.add(_SearchResult(
          message: message,
          conversationId: conversationId,
          conversationDisplayName: displayName,
          peerIds: peerIds,
        ));
      }
    }
  }

  /// Returns a display name and peer IDs for a conversation given only its ID.
  ///
  /// Reads peer IDs from local key metadata and resolves pseudos.
  Future<(String, List<String>)> _resolveConversationInfo(String conversationId) async {
    try {
      final meta = await _localStorage.readKeyMetadata(conversationId);
      if (meta != null && meta['peerIds'] is List) {
        final peerIds = List<String>.from(meta['peerIds'] as List);
        final currentUserId = _authService.currentUserId ?? '';
        final otherIds = peerIds.where((id) => id != currentUserId).toList();
        if (otherIds.isNotEmpty) {
          final pseudos = await _pseudoService.getDisplayNames(otherIds);
          final name = otherIds.map((id) => pseudos[id] ?? (id.length > 8 ? id.substring(0, 8) : id)).join(', ');
          return (name, peerIds);
        }
        return (
          conversationId.length > 8 ? conversationId.substring(0, 8) : conversationId,
          peerIds,
        );
      }
    } catch (_) {
      // Fall through to default
    }
    return (
      conversationId.length > 8 ? conversationId.substring(0, 8) : conversationId,
      <String>[],
    );
  }

  String _getConversationDisplayName(Conversation conversation) {
    final currentUserId = _authService.currentUserId ?? '';
    final otherIds = conversation.peerIds.where((id) => id != currentUserId).toList();
    if (otherIds.isEmpty) return conversation.displayName;
    return otherIds
        .map((id) => id.length > 8 ? id.substring(0, 8) : id)
        .join(', ');
  }

  void _openConversation(_SearchResult result) {
    // Use the full conversation object if searching within a known conversation,
    // otherwise reconstruct a minimal one from the search result's metadata.
    final conv = widget.conversation ??
        Conversation(id: result.conversationId, peerIds: result.peerIds);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationDetailScreen(conversation: conv),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isSingleConversation = widget.conversation != null;
    final String hintText = isSingleConversation
        ? 'Rechercher dans cette conversation...'
        : 'Rechercher dans les conversations...';

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hintText,
            border: InputBorder.none,
          ),
          onChanged: _search,
          enableIMEPersonalizedLearning: false,
          enableSuggestions: false,
          autocorrect: false,
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Effacer',
              onPressed: () {
                _searchController.clear();
                _search('');
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_lastQuery.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Tapez pour rechercher des messages',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Aucun résultat pour "$_lastQuery"',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return _SearchResultTile(
          result: result,
          query: _lastQuery,
          showConversationName: widget.conversation == null,
          onTap: () => _openConversation(result),
        );
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  final _SearchResult result;
  final String query;
  final bool showConversationName;
  final VoidCallback onTap;

  const _SearchResultTile({
    required this.result,
    required this.query,
    required this.showConversationName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = result.message.textContent ?? '';
    final formattedTime = FormatService.formatTimeRemaining(result.message.createdAt);

    return ListTile(
      title: showConversationName
          ? Text(
              result.conversationDisplayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            )
          : null,
      subtitle: _buildHighlightedText(context, text, query),
      trailing: Text(
        formattedTime,
        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
      ),
      onTap: onTap,
    );
  }

  Widget _buildHighlightedText(BuildContext context, String text, String query) {
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerText.indexOf(lowerQuery);

    if (matchIndex < 0) {
      return Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey[700]),
      );
    }

    // Trim leading context to keep the match visible in limited space
    const int contextChars = 30;
    final start = matchIndex > contextChars ? matchIndex - contextChars : 0;
    final displayText = start > 0 ? '…${text.substring(start)}' : text;
    final adjustedMatchIndex = matchIndex - start + (start > 0 ? 1 : 0);
    final matchEnd = adjustedMatchIndex + query.length;

    if (adjustedMatchIndex < 0 || matchEnd > displayText.length) {
      return Text(
        displayText,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey[700]),
      );
    }

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(color: Colors.grey[700]),
        children: [
          if (adjustedMatchIndex > 0)
            TextSpan(text: displayText.substring(0, adjustedMatchIndex)),
          TextSpan(
            text: displayText.substring(adjustedMatchIndex, matchEnd),
            style: TextStyle(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (matchEnd < displayText.length)
            TextSpan(text: displayText.substring(matchEnd)),
        ],
      ),
    );
  }
}
