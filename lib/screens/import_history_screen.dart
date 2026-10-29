import 'package:flutter/material.dart';

import '../services/diary_controller.dart';

class ImportHistoryScreen extends StatelessWidget {
  const ImportHistoryScreen({
    super.key,
    required this.controller,
    required this.tr,
  });

  final DiaryController controller;
  final String Function(String) tr;

  Future<void> _confirmDelete(
    BuildContext context,
    Map<String, dynamic> batch,
  ) async {
    final ids = (batch['entryIds'] as List? ?? []).map((e) => '$e').toSet();
    final edited = (batch['editedIds'] as List? ?? []).map((e) => '$e').toSet();
    final rows = controller.entries
        .where((row) => ids.contains('${row['id']}'))
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete statement?')),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${batch['fileName']}'),
                const SizedBox(height: 12),
                Text(
                  tr(
                    'This removes the saved transactions from this statement, including edited transactions.',
                  ),
                ),
                Text(
                  '${rows.length} ${tr('transactions')} • ${tr('Edited transactions')}: ${rows.where((row) => edited.contains('${row['id']}')).length}',
                ),
                for (final account in controller.accounts)
                  if (rows.any((row) => row['accountId'] == account['id']))
                    Text(
                      "${account['name'] ?? ''}: ${rows.where((row) => row['accountId'] == account['id']).length} ${tr('transactions')}",
                    ),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  Text(tr('No transactions remain in this statement.')),
                for (final row in rows)
                  ListTile(
                    dense: true,
                    title: Text('${row['description']}'),
                    subtitle: Text(
                      '${row['date']} • ${controller.accounts.where((a) => a['id'] == row['accountId']).map((a) => '${a['name']}').firstOrNull ?? ''}',
                    ),
                    trailing: Text(
                      '${row['amount']} ${row['currency'] ?? 'ILS'}',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final currentIds = controller.entries
          .where((row) => ids.contains('${row['id']}'))
          .map((row) => '${row['id']}')
          .toSet();
      final shownIds = rows.map((row) => '${row['id']}').toSet();
      if (currentIds.length != shownIds.length ||
          !currentIds.containsAll(shownIds)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('A transaction changed since review. Review it again.'),
            ),
          ),
        );
        return;
      }
      await controller.deleteImport('${batch['id']}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('Import history'))),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final batches = controller.imports.reversed.toList();
        if (batches.isEmpty) {
          return Center(child: Text(tr('No saved statements yet')));
        }
        final entries = controller.entries;
        return ListView.builder(
          itemCount: batches.length,
          itemBuilder: (context, index) {
            final batch = batches[index];
            final ids = (batch['entryIds'] as List? ?? [])
                .map((e) => '$e')
                .toSet();
            final count = entries
                .where((row) => ids.contains('${row['id']}'))
                .length;
            final accountIds =
                (batch['accountIds'] as List? ?? [batch['accountId']])
                    .map((id) => '$id')
                    .toSet();
            final accountNames = controller.accounts
                .where((account) => accountIds.contains('${account['id']}'))
                .map((account) => '${account['name'] ?? ''}')
                .where((name) => name.isNotEmpty)
                .join(', ');
            return Card(
              child: ListTile(
                title: Text('${batch['fileName']}'),
                subtitle: Text(
                  '$accountNames • ${tr('Imported')}: ${'${batch['importedAt']}'.split('T').first} • $count ${tr('transactions')}',
                ),
                trailing: IconButton(
                  tooltip: tr('Delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, batch),
                ),
                onTap: () => _confirmDelete(context, batch),
              ),
            );
          },
        );
      },
    ),
  );
}
