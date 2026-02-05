# OneTime - Messagerie Chiffrée

OneTime est une application pour s'envoyer des messages via un numéro de téléphone.
Ces messages sont chiffrés avec une clé partagée avant. 

**On partage une clé avant, on communique secrètement après.**

L'app sûre qui te force à voir des gens IRL.

## La clé c'est la clé

Une conversation à 2 à 3 ou à 100 c'est une clé.

Une conversation avec du texte des fichiers etc, c'est une clé.

Quand tu rencontres les gens, tu partages de kilo-octets ou des méga-octets de clé.

Ensuite à chaque message, une partie de la clé est consommée pour le protéger pour toujours.

Une conversation = une clé.

## Itinéraire d'un message crypté

1. J'écris mon message, "Yo" c'est 2 octets
2. Pour l'envoyer, je onetimepad le message avec les 2 prochains octets de la clé
3. Le message chiffré est posé sur le serveur (on utilise Firebase)
4. Un ami se connecte et collecte le message qu'il n'a pas encore sur son téléphone
5. Il utilise les 2 octets de la clé pour déchiffrer le message
6. Le message "Yo" apparaît sur son téléphone
7. Quand tout le monde a lu le message, le message est supprimé du serveur
8. Les 2 octets de clé ne seront jamais réutilisés et donc détruits

## Local versus le cloud

Le but est de n'avoir rien d'important sur le cloud.
- les messages sont effacés le plus tôt possible
- les index et tailles des clés de chacun pour détecter un départ ou une arrivée
- uniquement des identifiants aléatoires des participants, pas de courriels, pas de numéro de téléphone, pas de pseudos 

| Local (téléphone)            | Cloud (Firebase)                                             |
|------------------------------|--------------------------------------------------------------|
| Messages décryptés           | Messages chiffrés, le temps que tout le monde les récupèrent |
| Pseudos                      | identifiants aléatoires                                      |
| Clés de chiffrement binaires | Un objet conversation, les tailles des clés de chacun        |

## Open source

C'est un projet pour s'amuser avec un algorithme de chiffrement différent.
- notre but est de partager ce projet
- de valider sa sécurité
- de faire réviser le code par des experts, si ça les tente

Le repo est ici: 

## Architecture

### Services

#### 1. AuthService
Authentification Firebase anonyme.

#### 2. RandomKeyGeneratorService
Génération de clés aléatoires avec source d'entropie caméra.
- Utilise les variations RGB entre pixels comme source d'entropie
- XOR avec CSPRNG pour renforcer l'aléatoire
- Tests statistiques intégrés (Chi², fréquence, runs)

#### 3. KeyExchangeService
Échange local de clé via QR code.
- Source affiche les QR codes avec les bits de clé
- Lecteurs scannent et confirment via réseau (index uniquement)
- Les bits de clé ne transitent JAMAIS sur le réseau
- Support de l'agrandissement de clé existante

#### 4. CryptoService
Chiffrement/déchiffrement One-Time Pad.
- XOR du message avec la clé
- Gestion automatique des segments par peer
- Support des longs messages (multi-segments)
- Mode ultra-secure avec suppression après lecture

#### 5. FirebaseMessageService
Communication cloud sécurisée.
- Locks transactionnels avant envoi
- Synchronisation des segments utilisés
- Confirmation d'échange de clé (indices seulement)
- Support du mode suppression après lecture

#### 6. ContactsService
Gestion des contacts par numéro de téléphone.
- Import depuis le répertoire téléphone (uniquement contacts avec numéro)
- Vérification des utilisateurs OneTime par numéro
- Stockage local des contacts
- Association avec les clés partagées

### Modèles

#### UserProfile
Profil utilisateur identifié par son numéro de téléphone.
- Numéro de téléphone (identifiant unique)
- Nom d'affichage optionnel
- Dates de création/connexion

#### Contact
Contact de l'application.
- Numéro de téléphone normalisé (identifiant)
- Nom d'affichage
- Statut utilisateur OneTime
- Association clé partagée

#### SharedKey
Clé partagée avec métadonnées.
- Division automatique en segments par peer (ID croissant)
- Bitmap d'utilisation pour éviter réutilisation
- Méthodes d'extension et compaction

#### KeySegment
Représente un segment de clé utilisé.
- Tracking de l'utilisation (peer, timestamp)
- Détection de chevauchement

#### EncryptedMessage
Message chiffré prêt pour transmission.
- Support multi-segments pour longs messages
- Métadonnées pour déchiffrement

### Écrans

#### LoginScreen
Écran de connexion par numéro de téléphone:
- Sélection du code pays
- Saisie du numéro
- Envoi et vérification du code OTP

#### HomeScreen
Écran principal avec:
- Onglet Messages (conversations)
- Onglet Contacts
- Accès au profil via avatar

#### ProfileScreen
Gestion du profil:
- Numéro de téléphone (identifiant vérifié)
- Dates de création/connexion
- Informations de sécurité
- Bouton déconnexion
- Suppression de compte

#### ContactsScreen
Liste des contacts:
- Recherche
- Badge "OneTime" pour utilisateurs de l'app
- Icône clé si clé partagée existe
- Actions: créer clé, envoyer message, supprimer

#### ContactPickerScreen
Import de contacts téléphone:
- Demande de permission
- Affiche uniquement les contacts avec numéro
- Mise en avant des utilisateurs OneTime
- Import en un tap

## Protocole d'échange de clé

### Échange initial (2+ personnes)
1. **Source** génère une clé aléatoire
2. **Source** affiche QR codes segment par segment (1024 octets chacun)
3. **Lecteurs** scannent chaque QR code
4. **Lecteurs** confirment via cloud/radio: `{sessionId, peerId, segmentIndex}`
5. **Important**: Seuls les INDEX sont envoyés, jamais les bits

### Agrandissement de clé
1. Créer une session d'extension sur la clé existante
2. Répéter le protocole d'échange pour les nouveaux segments
3. La nouvelle clé est concaténée à l'existante

## Stratégie d'utilisation de la clé

### Pour 2 peers
- Peer avec ID le plus bas: utilise depuis le début
- Peer avec ID le plus haut: utilise depuis la fin

### Pour N peers
- Peers triés par ID croissant
- Peer i utilise le segment `[i*length/N, (i+1)*length/N[`

## Mode Ultra-Secure

1. Message chiffré et envoyé
2. Destinataire déchiffre
3. **Suppression immédiate** de:
   - Message sur le cloud
   - Bits de clé locaux (mis à zéro)
4. Le message ne peut plus jamais être déchiffré

## Configuration Firebase

### firebase_options.dart
Créer le fichier avec FlutterFire CLI:
```bash
flutterfire configure
```

### Activer l'authentification par téléphone
1. Firebase Console > Authentication > Sign-in method
2. Activer "Téléphone"
3. Ajouter les numéros de test si besoin (pour le développement)

### Règles Firestore
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Utilisateurs identifiés par leur UID Firebase
    match /users/{userId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Messages chiffrés
    match /messages/{messageId} {
      allow read, write: if request.auth != null;
    }
  }
}
```

## Tests

```bash
flutter test
```

Tests inclus:
- Chi² pour uniformité du générateur
- Test de fréquence (proportion 0/1)
- Test des runs (séquences consécutives)
- Chiffrement/déchiffrement
- Gestion des segments

## Capacité QR Code

| Version | Octets max | Bits |
|---------|------------|------|
| 10 | 174 | 1,392 |
| 15 | 412 | 3,296 |
| 20 | 666 | 5,328 |
| 25 | 1,024 | 8,192 |
| 30 | 1,370 | 10,960 |
| 40 | 2,953 | 23,624 |

## Dépendances

```yaml
dependencies:
  # Firebase
  firebase_core: ^3.8.1
  firebase_auth: ^5.3.4
  cloud_firestore: ^5.6.0
  
  # Contacts
  flutter_contacts: ^1.1.9+2
  
  # QR Code
  qr_flutter: ^4.1.0
  mobile_scanner: ^6.0.2
  
  # Camera for entropy
  camera: ^0.11.0+2
  
  # Local storage
  shared_preferences: ^2.3.4
```

## Sécurité

### Pourquoi c'est sécurisé ?
- **Chiffrement One-Time Pad** : Mathématiquement prouvé inviolable si la clé est vraiment aléatoire et utilisée une seule fois
- **Échange de clé hors-ligne** : Les bits de clé ne transitent jamais sur Internet, uniquement via QR code en présence physique
- **Pas de serveur de clés** : Le serveur ne voit que des messages chiffrés, il ne peut pas les déchiffrer
- **Identité minimale** : Seul le numéro de téléphone est utilisé, pas d'email, pas de mot de passe

### Ce que le serveur voit
- Les numéros de téléphone des utilisateurs
- Les messages chiffrés (illisibles sans la clé)
- Les timestamps et métadonnées de livraison

### Ce que le serveur ne voit PAS
- Le contenu des messages
- Les clés de chiffrement
- Aucune information permettant de déchiffrer les messages

