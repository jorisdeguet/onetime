import 'package:flutter/material.dart';
import 'package:onetime/convo/encrypted_message.dart';

import '../services/media_service.dart';

/// Dialogue de confirmation pour l'envoi d'un média (image ou fichier).
///
/// Affiche les informations sur la taille du fichier, les bits de clé nécessaires,
/// et permet de choisir la qualité pour les images.
class MediaConfirmDialog extends StatefulWidget {
  final MediaPickResult mediaResult;
  final int availableKeyBits;
  final Function(MediaPickResult, ImageQuality?)? onQualityChanged;

  const MediaConfirmDialog({
    super.key,
    required this.mediaResult,
    required this.availableKeyBits,
    this.onQualityChanged,
  });

  /// Affiche le dialogue et retourne true si l'utilisateur confirme
  static Future<MediaSendConfirmation?> show({
    required BuildContext context,
    required MediaPickResult mediaResult,
    required int availableKeyBits,
    required MediaService mediaService,
  }) async {
    return showDialog<MediaSendConfirmation>(
      context: context,
      builder: (context) => _MediaConfirmDialogContent(
        mediaResult: mediaResult,
        availableKeyBits: availableKeyBits,
        mediaService: mediaService,
      ),
    );
  }

  @override
  State<MediaConfirmDialog> createState() => _MediaConfirmDialogState();
}

class _MediaConfirmDialogState extends State<MediaConfirmDialog> {
  @override
  Widget build(BuildContext context) {
    return const Placeholder();
  }
}

class _MediaConfirmDialogContent extends StatefulWidget {
  final MediaPickResult mediaResult;
  final int availableKeyBits;
  final MediaService mediaService;

  const _MediaConfirmDialogContent({
    required this.mediaResult,
    required this.availableKeyBits,
    required this.mediaService,
  });

  @override
  State<_MediaConfirmDialogContent> createState() => _MediaConfirmDialogContentState();
}

class _MediaConfirmDialogContentState extends State<_MediaConfirmDialogContent> {
  ImageQuality _selectedQuality = ImageQuality.medium;
  MediaPickResult? _currentResult;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _currentResult = widget.mediaResult;
  }

  bool get _hasEnoughKey =>
      _currentResult != null &&
      _currentResult!.bitsNeeded <= widget.availableKeyBits;

  double get _keyUsagePercent {
    if (widget.availableKeyBits == 0 || _currentResult == null) return 100;
    return (_currentResult!.bitsNeeded / widget.availableKeyBits) * 100;
  }

  Future<void> _onQualityChanged(ImageQuality? quality) async {
    if (quality == null || _isProcessing) return;
    if (widget.mediaResult.contentType != MessageContentType.image) return;

    setState(() {
      _selectedQuality = quality;
      _isProcessing = true;
    });

    // Recharger et redimensionner l'image avec la nouvelle qualité
    // Note: Dans une vraie implémentation, on garderait l'image originale en mémoire
    // Pour simplifier, on utilise juste le résultat actuel

    setState(() {
      _isProcessing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaService = widget.mediaService;
    final result = _currentResult!;
    final isImage = result.contentType == MessageContentType.image;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isImage ? Icons.image : Icons.attach_file,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isImage ? 'Envoyer une image' : 'Envoyer un fichier',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Aperçu pour les images
            if (isImage) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  result.data,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Nom du fichier
            Row(
              children: [
                const Icon(Icons.description, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.fileName,
                    style: Theme.of(context).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Taille du fichier
            Row(
              children: [
                const Icon(Icons.storage, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  'Taille: ${mediaService.formatSize(result.finalSize)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (result.wasResized) ...[
                  const SizedBox(width: 8),
                  Text(
                    '(${result.compressionPercent.toStringAsFixed(0)}% compressé)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            // Bits de clé nécessaires
            Row(
              children: [
                Icon(
                  Icons.key,
                  size: 16,
                  color: _hasEnoughKey ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Clé nécessaire: ${mediaService.formatKeyBits(result.bitsNeeded)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _hasEnoughKey ? null : Colors.red,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Clé disponible
            Row(
              children: [
                const Icon(Icons.lock, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Clé disponible: ${mediaService.formatKeyBits(widget.availableKeyBits)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),

            // Barre de progression de l'utilisation de la clé
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _keyUsagePercent / 100,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(
                _hasEnoughKey
                    ? (_keyUsagePercent > 50 ? Colors.orange : Colors.green)
                    : Colors.red,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_keyUsagePercent.toStringAsFixed(1)}% de la clé disponible',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey,
              ),
            ),

            // Sélecteur de qualité pour les images
            if (isImage) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Qualité de l\'image',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ImageQuality.values.map((quality) {
                  final isSelected = _selectedQuality == quality;
                  return ChoiceChip(
                    label: Text(quality.label),
                    selected: isSelected,
                    onSelected: _isProcessing ? null : (_) => _onQualityChanged(quality),
                  );
                }).toList(),
              ),
            ],

            // Avertissement si pas assez de clé
            if (!_hasEnoughKey) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withAlpha(76)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pas assez de clé disponible. '
                        '${isImage ? "Essayez une qualité inférieure ou " : ""}'
                        'effectuez un nouvel échange de clé.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: _hasEnoughKey && !_isProcessing
              ? () => Navigator.of(context).pop(
                    MediaSendConfirmation(
                      result: _currentResult!,
                      selectedQuality: isImage ? _selectedQuality : null,
                    ),
                  )
              : null,
          child: _isProcessing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Envoyer'),
        ),
      ],
    );
  }
}

/// Résultat de la confirmation d'envoi
class MediaSendConfirmation {
  final MediaPickResult result;
  final ImageQuality? selectedQuality;

  MediaSendConfirmation({
    required this.result,
    this.selectedQuality,
  });
}

