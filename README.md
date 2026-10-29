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

Use `flutter build windows --release` for a Windows application folder. Keep the executable, OCR engine, libraries and assets together. An Android release build requires an existing release keystore and a local `android/key.properties` file:

```properties
storeFile=path/to/release-keystore.jks
storePassword=your-store-password
keyAlias=your-key-alias
keyPassword=your-key-password
```

The keystore path is relative to the `android` directory unless absolute. Never commit credentials or keystores. `flutter build apk --release` fails without valid signing configuration; debug builds continue to use the debug key. The current `com.example.finance_diary` package ID is retained to preserve existing debug installations. Before distributing, choose a permanent package ID and export an encrypted backup; a different package ID or signing key requires a separate installation and backup restore, not an in-place upgrade.

## Using the diary

Create a passcode of at least eight characters. It encrypts the local diary using AES-256-GCM with a PBKDF2-HMAC-SHA256 derived key. There is no account, server, or passcode recovery: keep an encrypted backup and remember its passcode. Backups can be restored on another device from the opening screen. Restoring replaces that device's current diary.

On Windows the app preserves the original diary location across product-name changes. If different encrypted diaries exist at both the old and new locations, choose which one to open; the selection does not modify either file.

Add a bank account or card, then choose **Import statement** for that account. Map the columns, review every proposed transaction and add or correct missing entries before confirming. Imports are separate for each account. The app can read PDF text, CSV/TSV, spreadsheet formats and HTML exports saved with an `.xls` extension. The sample Leumi card-charge file contains payment summaries, not individual purchases.

The supplied Leumi and Beinleumi bank-statement layouts have separate PDF importers. The detected bank is shown during review; combine neither bank's statements with another provider in one file. Unknown layouts use the generic importer and may need manual mapping or entry. Compare every imported transaction with the original before saving.

Map debit and credit to their own columns when available. For unsigned bank amounts, choose income or expense during review; the app will not save unclassified rows. For card charges, unsigned amounts default to expenses and can be corrected individually. To fix an earlier import, open an entry in the Diary and choose its income/expense direction, or filter the Diary and use **Mark shown as expenses** or **Mark shown as income** after confirmation. You can also delete individual entries, or use **Delete transactions** to remove the shown entries after confirmation. Deleting an account also removes its transactions after confirmation.

PDF extraction and OCR can miss or misread transactions, amounts or signs. Always compare the review screen with all pages of the original statement. Scanned pages use position-aware OCR, and their proposed income or expense directions require confirmation. A page containing both selectable transactions and image-only rows may still need manual entries; the app warns when it cannot rule this out. Android and Windows include offline OCR for Hebrew, English and Russian. Windows verifies and locks the bundled OCR engine and language models before use; missing or altered components are reported instead of running an unverified program. OCR uses temporary app-cache images that are removed after use; an interrupted process may leave temporary files until the next cleanup. The file picker may also create temporary copies.

New imports automatically skip exact matches with existing transactions in the same account. Review the skipped rows before saving: identical legitimate transactions are possible, so you can keep both or choose the imported row instead. Review possible duplicates already in the diary and suggested card-payment links in the reconciliation queue. Linked card summaries and bank payments are excluded from combined spending only when their linked amounts reconcile; partial matches remain included and should be reviewed to avoid double counting.

Import history lists statements saved after this feature was added. You can preview and remove all saved transactions from a statement, including edited transactions. Older statements cannot be grouped reliably; use the account's clear-transactions action to remove all its transactions while retaining the account and opening balance. Both actions require confirmation. Import history and reconciliation choices are stored in the encrypted diary and its backups; devices do not synchronize automatically.

Forecasts are estimates derived from historical records and planned entries. Supply a current bank balance to see a projected balance. Foreign currency amounts use the statement's ILS value when present; otherwise public Bank of Israel exchange rates can be downloaded and cached. Only currency and date are sent to the rate service, never descriptions, amounts or statements. You can also enter a dated rate manually. Missing rates are excluded from ILS totals and flagged.

## Privacy and project status

Do not commit real statements, backups, or financial data. Tests use synthetic examples. Statement import requires careful review, and support for unseen layouts is not guaranteed. The bundled Android OCR engine's complete third-party notices and binary provenance should be verified before distributing a release; Windows OCR provenance and notices are in `windows/ocr`.
