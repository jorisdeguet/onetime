import 'package:flutter/material.dart';
import 'package:onetime/services/message_service.dart';
import 'package:onetime/services/key_service.dart';
import 'package:onetime/l10n/app_localizations.dart';
import 'package:onetime/services/app_logger.dart';
import 'package:onetime/services/format_service.dart';
import 'package:onetime/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Profile screen with settings
class ProfileScreen extends StatefulWidget {
  final Function(ThemeMode)? onThemeModeChanged;

  const ProfileScreen({super.key, this.onThemeModeChanged});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final AuthService _authService = AuthService();
  final KeyService _keyService = KeyService();
  final MessageService _messageService = MessageService.fromCurrentUserID();
  final _log = AppLogger();

  bool _isLoading = false;
  ThemeMode _themeMode = ThemeMode.system;
  int _totalKeyBytes = 0;
  int _totalMessageBytes = 0;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _calculateStorageUsage();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeString = prefs.getString('theme_mode') ?? 'system';
    setState(() {
      _themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == themeModeString,
        orElse: () => ThemeMode.system,
      );
    });
  }

  Future<void> _saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
    setState(() {
      _themeMode = mode;
    });
    widget.onThemeModeChanged?.call(mode);
  }

  Future<void> _calculateStorageUsage() async {
    try {
      int keyBytes  = await _keyService.getTotalKeyStorageUsedBytes();
      int messageBytes = 0;
      final conversationIds = await _keyService.listConversations();
      
      for (final convId in conversationIds) {

        // Calculate message size (approximate)
        final messagesSize = await _messageService.getConversationSize(convId);
        messageBytes += messagesSize;
      }
      if (mounted) {
        setState(() {
          _totalKeyBytes = keyBytes;
          _totalMessageBytes = messageBytes;
        });
      }
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _nukeAllData() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.red[700]),
            const SizedBox(width: 8),
            Text(l10n.get('profile_nuke_title')),
          ],
        ),
        content: Text(l10n.get('profile_nuke_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('💣 NUKE'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      try {
        // Delete all local storage
        final conversationIds = await _keyService.listConversations();
        
        for (final convId in conversationIds) {
          await _keyService.deleteKey(convId);
          await _messageService.deleteConversationMessages(convId);
          await _messageService.deleteUnreadCount(convId);
        }
        
        // Delete global data
        await _messageService.deleteAllUnreadCounts();

        // Supprimer le compte Firebase (reset complet de l'identité)
        try {
          await _authService.deleteAccount();
        } catch (e) {
          _log.e('Profile', 'Error deleting account: $e');
          // On continue même si erreur pour finir le nettoyage local
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.get('profile_nuke_success')),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
          
          // Recalculate storage
          await _calculateStorageUsage();
          
          // Return to home
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${l10n.get('error_generic')}: $e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }


  Future<void> _importConversations() async {
    // Show dialog with text input
    final controller = TextEditingController();
    
    final shouldImport = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Importer des conversations'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Collez les données d\'export (JSON) ci-dessous:',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{"conversationId": "...", ...}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Importer'),
          ),
        ],
      ),
    );

    if (shouldImport != true || !mounted) return;

    setState(() => _isLoading = true);


  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final userId = _authService.currentUserId;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.get('profile_title')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : userId == null
              ? Center(child: Text(l10n.get('auth_not_connected')))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Dark mode selector
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.brightness_6, size: 20, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.get('settings_theme'),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SegmentedButton<ThemeMode>(
                                segments: [
                                  ButtonSegment(
                                    value: ThemeMode.light,
                                    label: Text(l10n.get('settings_theme_light')),
                                    icon: const Icon(Icons.light_mode, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.dark,
                                    label: Text(l10n.get('settings_theme_dark')),
                                    icon: const Icon(Icons.dark_mode, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.system,
                                    label: Text(l10n.get('settings_theme_system')),
                                    icon: const Icon(Icons.brightness_auto, size: 18),
                                  ),
                                ],
                                selected: {_themeMode},
                                onSelectionChanged: (Set<ThemeMode> newSelection) {
                                  _saveThemeMode(newSelection.first);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Storage usage
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.storage, size: 20, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.get('settings_storage'),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _StorageRow(
                                icon: Icons.key,
                                label: l10n.get('settings_storage_keys'),
                                value: FormatService.formatBytes(_totalKeyBytes),
                              ),
                              const SizedBox(height: 8),
                              _StorageRow(
                                icon: Icons.message,
                                label: l10n.get('settings_storage_messages'),
                                value: FormatService.formatBytes(_totalMessageBytes),
                              ),
                              const Divider(height: 20),
                              _StorageRow(
                                icon: Icons.folder,
                                label: l10n.get('settings_storage_total'),
                                value: FormatService.formatBytes(_totalKeyBytes + _totalMessageBytes),
                                bold: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Import/Export section
                      Text(
                        'Sauvegarde',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _importConversations,
                          icon: const Icon(Icons.download),
                          label: const Text('Importer des conversations'),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Nuke section
                      Text(
                        l10n.get('settings_danger_zone'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.red[700],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.get('settings_nuke_explanation'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _nukeAllData,
                          icon: const Icon(Icons.delete_sweep),
                          label: const Text('💣 NUKE'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _StorageRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool bold;

  const _StorageRow({
    required this.icon,
    required this.label,
    required this.value,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
