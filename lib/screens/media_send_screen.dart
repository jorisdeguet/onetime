import 'package:flutter/material.dart';
import 'package:onetime/models/firestore/fs_message.dart';
import 'package:onetime/services/lock_service.dart';
import 'package:onetime/services/message_service.dart';
import 'package:onetime/services/format_service.dart';
import 'package:onetime/services/media_service.dart';

/// Full screen for sending media with preview and debug
class MediaSendScreen extends StatefulWidget {
  final MediaPickResult mediaResult;
  final String conversationId;
  final String currentUserId;

  const MediaSendScreen({
    super.key,
    required this.mediaResult,
    required this.conversationId,
    required this.currentUserId,
  });

  @override
  State<MediaSendScreen> createState() => _MediaSendScreenState();
}

class _MediaSendScreenState extends State<MediaSendScreen> {
  bool _isProcessing = false;
  bool _isComplete = false;
  String? _errorMessage;
  ImageQuality _selectedQuality = ImageQuality.medium;
  MediaPickResult? _currentResult;

  final MessageService _messageService = MessageService.fromCurrentUserID();

  @override
  void initState() {
    super.initState();
    _currentResult = widget.mediaResult;
  }

  Future<void> _changeQuality(ImageQuality quality) async {
    if (widget.mediaResult.contentType != MessageContentType.image) return;
    setState(() {
      _selectedQuality = quality;
    });
  }

  Future<void> _sendMedia() async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    try{
      await _messageService.sendMedia(_currentResult!, widget.conversationId);
      setState(() {
        _isComplete = true;
        _isProcessing = false;
      });
      // Retourner après 1 seconde
      await Future.delayed(const Duration(milliseconds: 10));
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on LockAcquisitionException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final neededBytes = _currentResult!.data.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Envoyer un média'),  // TODO i18n
      ),
      body: Column(
        children: [
          // Preview de l'image/fichier
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.black,
              child: Center(
                child: _currentResult!.contentType == MessageContentType.image
                    ? Image.memory(
                        _currentResult!.data,
                        fit: BoxFit.contain,
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.insert_drive_file, size: 64, color: Colors.white),
                          const SizedBox(height: 16),
                          Text(
                            _currentResult!.fileName,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
              ),
            ),
          ),

          // Sélection de qualité pour images
          if (_currentResult!.contentType == MessageContentType.image && !_isComplete)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.grey[200],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Qualité:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: ImageQuality.values.map((quality) {
                      return ChoiceChip(
                        label: Text(quality.label),
                        selected: _selectedQuality == quality,
                        onSelected: _isProcessing ? null : (_) => _changeQuality(quality),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          // Boutons d'action
          if (!_isComplete)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessing ? null : _sendMedia,
                        icon: _isProcessing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                        label: Text(
                           'Envoyer (${FormatService.formatBytes(neededBytes)})'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                          backgroundColor: null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isComplete)
            SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.green[100],
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 32),
                    SizedBox(width: 12),
                    Text(
                      'Envoyé avec succès!',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
