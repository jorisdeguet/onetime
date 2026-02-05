# TODO payant
- implanter un mode payant pour débloquer:
  - envoi de fichier de plus de 1 Mo
  - nombre illimité de messages stockés (avant lecture de tous)
- Placer le séparateur de message dans le gros blob de messages
- Optimiser encodage QR (binaire au lieu de JSON/Base64) pour 3x plus de données
- Augmenter taille QR à 2048-2953 bytes (version 40)
- solliciter un don de temps en temps genre tous les 100 messages envoyés


# TODO core
- s'assurer qu'on peut créer supprimer des conversations et qu'on retourne à l'accueil
- implement a sanity check on start up that 1. once signed in 2. get all the local convos 3. get all the remote convos 4. validate remote versus local key interval 5. possible other validations
- marquer correctement les messages / intervalles lus
- s'assurer d'avoir idempotence sur tout
- merger les services comme key_service qui regroupe stockage et manipulation des clés
- centraliser les service dans des singletons gérés par getit 
