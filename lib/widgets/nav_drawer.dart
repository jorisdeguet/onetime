import 'package:flutter/material.dart';
import '../services/pseudo_service.dart';
import '../screens/home_screen.dart';
import '../screens/new_conversation_screen.dart';
import '../screens/join_conversation_screen.dart';
import '../screens/profile_screen.dart';

/// Reusable navigation drawer for all screens except pseudo setting screen
/// Provides navigation to conversations, create conversation, join conversation, and profile
class NavDrawer extends StatefulWidget {
  const NavDrawer({super.key});

  @override
  State<NavDrawer> createState() => _NavDrawerState();
}

class _NavDrawerState extends State<NavDrawer> {
  final PseudoService _pseudoService = PseudoService();
  String? _myPseudo;

  @override
  void initState() {
    super.initState();
    _loadMyPseudo();
  }

  Future<void> _loadMyPseudo() async {
    final pseudo = await _pseudoService.getMyPseudo();
    if (mounted) {
      setState(() {
        _myPseudo = pseudo;
      });
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomeScreen()),
      (route) => false,
    );
  }

  void _navigateToCreateConversation() {
    Navigator.pop(context); // Close drawer
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NewConversationScreen()),
    );
  }

  void _navigateToJoinConversation() {
    Navigator.pop(context); // Close drawer
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const JoinConversationScreen()),
    );
  }

  void _navigateToProfile() {
    Navigator.pop(context); // Close drawer
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(onThemeModeChanged: null)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Drawer Header
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '1 time',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (_myPseudo != null && _myPseudo!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      _myPseudo!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),

          // Home / Conversations
          ListTile(
            leading: const Icon(Icons.home),
            title: const Text('Conversations'),
            onTap: _navigateToHome,
          ),

          // Create Conversation
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('Create Conversation'),
            onTap: _navigateToCreateConversation,
          ),

          // Join Conversation
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('Join Conversation'),
            onTap: _navigateToJoinConversation,
          ),

          const Divider(),

          // Profile
          ListTile(
            leading: const Icon(Icons.account_circle),
            title: const Text('Profile'),
            onTap: _navigateToProfile,
          ),
        ],
      ),
    );
  }
}

