# Financial Diary

A local-first Flutter financial diary for Android and Windows. Create separate bank and credit-card accounts, import statements for review, track income and expenses, and explore estimated cash flow. The interface supports English, Hebrew and Russian.

## Build and run

Install Flutter and the Android SDK or Windows desktop toolchain, then run:

```sh
flutter pub get
flutter test
flutter run -d windows
flutter run -d <android-device-id>
```

Use `flutter build windows --release` for a Windows application folder, or `flutter build apk --release` for an Android APK. Windows release output consists of the executable and its accompanying libraries and assets; keep the folder together.

## Using the diary

Create a passcode of at least eight characters. It encrypts the local diary using AES-256-GCM with a PBKDF2-HMAC-SHA256 derived key. There is no account, server, or passcode recovery: keep an encrypted backup and remember its passcode. Backups can be restored on another device from the opening screen. Restoring replaces that device's current diary.

Add a bank account or card, then choose **Import statement** for that account. Map the columns, review every proposed transaction and add or correct missing entries before confirming. Imports are separate for each account. The app can read PDF text, CSV/TSV, spreadsheet formats and HTML exports saved with an `.xls` extension. The sample Leumi card-charge file contains payment summaries, not individual purchases.

Map debit and credit to their own columns when available. For unsigned bank amounts, choose income or expense during review; the app will not save unclassified rows. For card charges, unsigned amounts default to expenses and can be corrected individually. To fix an earlier import, open an entry in the Diary and choose its income/expense direction, or filter the Diary and use **Mark shown as expenses** or **Mark shown as income** after confirmation. You can also delete individual entries, or use **Delete transactions** to remove the shown entries after confirmation. Deleting an account also removes its transactions after confirmation.

PDF extraction and OCR are heuristic and can miss or misread transactions, amounts or signs. Always compare the review screen with all pages of the original statement. Android includes offline OCR for Hebrew, English and Russian. Windows OCR currently requires a separately installed Tesseract 4+ executable on `PATH` or in a `tesseract` folder next to the app; if unavailable, image-only pages are flagged and can be entered manually. OCR uses temporary app-cache images that are removed after use; an interrupted process may leave temporary files until the next cleanup. The file picker may also create temporary copies.

Possible duplicates and card-payment links are suggestions, not automatic changes. Confirm matches or use the link action in the diary. Linked card summaries and bank payments are excluded from combined spending only when their linked amounts reconcile; partial matches remain included and should be reviewed to avoid double counting.

Forecasts are estimates derived from historical records and planned entries. Supply a current bank balance to see a projected balance. Foreign currency amounts use the statement's ILS value when present; otherwise public Bank of Israel exchange rates can be downloaded and cached. Only currency and date are sent to the rate service, never descriptions, amounts or statements. You can also enter a dated rate manually. Missing rates are excluded from ILS totals and flagged.

## Privacy and project status

Do not commit real statements, backups, or financial data. Tests use synthetic examples. Statement import requires careful review, and support for unseen layouts is not guaranteed. Windows OCR currently has the external dependency noted above; the bundled Android OCR engine's complete third-party notices and binary provenance should be verified before distributing a release.
