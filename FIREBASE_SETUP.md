# Firebase Setup Instructions

This project uses Firebase for backend services. Follow these steps to configure Firebase for local development.

## Prerequisites

- Flutter SDK installed
- Firebase CLI installed (`npm install -g firebase-tools`)
- FlutterFire CLI installed (`dart pub global activate flutterfire_cli`)
- Access to the Firebase project

## Setup Steps

1. **Login to Firebase:**
   ```bash
   firebase login
   ```

2. **Configure FlutterFire:**
   ```bash
   flutterfire configure
   ```
   
   This will:
   - Connect to your Firebase project
   - Generate `lib/config/firebase_options.dart`
   - Create/update `android/app/google-services.json`
   - Create/update `ios/Runner/GoogleService-Info.plist`

3. **Verify Configuration:**
   - Ensure all three files above are created
   - These files are git-ignored for security
   - Never commit these files to version control

## Files Generated (Git-Ignored)

- `lib/config/firebase_options.dart` - Firebase configuration for Dart
- `android/app/google-services.json` - Android Firebase config
- `ios/Runner/GoogleService-Info.plist` - iOS Firebase config

## Notes

- Firebase API keys for web/mobile are protected by Firebase Security Rules
- Always regenerate keys if accidentally exposed
- Contact project admin for Firebase project access
