import 'package:firebase_auth/firebase_auth.dart';

import '../services/app_logger.dart';

/// Authentication service using Firebase Anonymous Auth.
class AuthService {
  // Singleton instance
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final _log = AppLogger();

  /// Signed-in user ID
  String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  /// Checks if a user is signed in
  bool get isSignedIn => FirebaseAuth.instance.currentUser != null;

  /// Initializes service and signs in anonymously if needed
  Future<bool> initialize() async {
    if (!isSignedIn) {
      _log.d('AuthService', 'No user signed in, attempting anonymous sign-in...');
      await signInAnonymously();
    } else {
      _log.d('AuthService', 'Already signed in with ID: $currentUserId');
    }
    return isSignedIn;
  }

  /// Signs in the user anonymously
  Future<String?> signInAnonymously() async {
    _log.d('AuthService', 'signInAnonymously');
    try {
      final userCredential = await FirebaseAuth.instance.signInAnonymously();
      final user = userCredential.user;
      _log.i('AuthService', 'Signed in anonymously with UID: ${user?.uid}');
      return user?.uid;
    } catch (e) {
      _log.e('AuthService', 'signInAnonymously ERROR: $e');
      throw Exception('AUTH Failed to sign in anonymously: $e');
    }
  }

  /// Alias to create a user (backward compatibility) - actually a sign in
  Future<String> createUser() async {
    // If already signed in, keep current user
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      _log.d('AuthService', 'createUser: Already signed in as ${currentUser.uid}');
      return currentUser.uid;
    }

    final uid = await signInAnonymously();
    if (uid == null) throw Exception('Auth Failed to retrieve UID after sign in');
    return uid;
  }

  /// Deletes user account
  Future<void> deleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('AUTH No user signed in');
    }

    try {
      await user.delete();
      _log.i('AuthService', 'Account deleted');
    } catch (e) {
      _log.e('AuthService', 'deleteAccount ERROR: $e');
      throw Exception('AUTH Failed to delete account: $e');
    }
  }
}
