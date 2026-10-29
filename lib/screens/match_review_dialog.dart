import 'package:flutter/material.dart';

/// The caller applies the selected action only after this dialog completes.
enum MatchReviewAction { deleteFirst, deleteSecond, link }

Future<MatchReviewAction?> showMatchReviewDialog({
  required BuildContext context,
  required Map<String, dynamic> match,
  required List<Map<String, dynamic>> entries,
  required List<Map<String, dynamic>> accounts,
  required String Function(String) tr,
}) async {
  final byId = {for (final row in entries) '${row['id']}': row};
  final first = byId['${match['firstId']}'];
  final second = byId['${match['secondId']}'];
  if (first == null || second == null) return null;
  final names = {for (final a in accounts) '${a['id']}': '${a['name']}'};
  final duplicate = match['type'] == 'duplicate';
  final relatedIds =
      (match['purchaseIds'] as List?)?.map((e) => '$e') ?? ['${second['id']}'];
  String details(Map<String, dynamic> row) =>
      '${names['${row['accountId']}'] ?? ''}\n${row['date']}  ${row['description']}\n${row['amount']} ${row['currency'] ?? 'ILS'}';

  final selection = await showDialog<MatchReviewAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        tr(duplicate ? 'Possible duplicate' : 'Possible card payment'),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (duplicate) Text(tr('First transaction')),
            Text(details(first)),
            const SizedBox(height: 16),
            if (duplicate) Text(tr('Second transaction')),
            for (final id in relatedIds)
              if (byId[id] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(details(byId[id]!)),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Cancel')),
        ),
        if (duplicate) ...[
          TextButton(
            key: const Key('delete-first-match'),
            onPressed: () =>
                Navigator.pop(context, MatchReviewAction.deleteFirst),
            child: Text(tr('Delete first')),
          ),
          TextButton(
            key: const Key('delete-second-match'),
            onPressed: () =>
                Navigator.pop(context, MatchReviewAction.deleteSecond),
            child: Text(tr('Delete second')),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.pop(context, MatchReviewAction.link),
            child: Text(tr('Link payments')),
          ),
      ],
    ),
  );
  if (selection == null || selection == MatchReviewAction.link) {
    return selection;
  }
  if (!context.mounted) return null;
  final selected = selection == MatchReviewAction.deleteFirst ? first : second;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Delete this transaction?')),
      content: Text(details(selected)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          key: const Key('confirm-delete-match'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Delete')),
        ),
      ],
    ),
  );
  return confirmed == true ? selection : null;
}
