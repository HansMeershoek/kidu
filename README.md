# KiDu

KiDu is a minimalist co-parent expense app focused on shared spending visibility between two co-parents. It uses invite-based household linking and provides clear shared expense tracking with balance and settlement clarity.

## Current Features

- Google sign-in
- Profile name setup after first login
- Household create/join via invite code
- Expense creation
- Balance calculation with settlement guidance text
- Switch account / sign out

## Tech Stack

- Flutter
- Firebase Authentication
- Cloud Firestore

## Supported Platforms

- Android (configured)
- iOS (configured)
- Web, macOS, Windows, and Linux are not configured in Firebase options

## Local Setup

1. Clone the repository.
2. Run `flutter pub get`.
3. Configure Firebase for this app (required): add platform-specific Firebase configuration files and ensure your Firebase project settings match the app IDs.
4. Start the app with `flutter run`.

## Security Note

The household is the primary security boundary in KiDu. There is no admin role; both co-parents have equal access within the household.

## Project Status

KiDu is in MVP-complete state and currently in a polish phase focused on stability, UX refinement, and production readiness.
