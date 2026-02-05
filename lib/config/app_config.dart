/// Configuration globale de l'application pour le développement et le debug
class AppConfig {
  /// Active/désactive l'échange automatique de pseudo au début d'une conversation
  /// Si false, les messages pseudo ne seront pas envoyés automatiquement
  static const bool pseudoExchangeStartConversation = false;

  /// When true, when a shared key becomes available for a conversation and
  /// the current user hasn't yet sent their pseudo, the app will automatically
  /// send the pseudo message (uses existing `_sendMyPseudo()` logic).
  /// This is helpful for a smooth UX after an initial key exchange.
  static const bool autoSendPseudoOnKeyAvailable = true;

  /// Active/désactive les logs de debug étendus pour le chiffrement
  static const bool verboseCryptoLogs = true;


  /// Liste des tags de logs à afficher. Si vide => afficher tous les tags.
  /// Exemple: ['KeyStorage', 'KeyExchange']
  static const List<String> enabledLogTags = ['UnreadMsg', 'LockService'];
}
