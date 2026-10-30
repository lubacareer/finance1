import 'package:flutter/material.dart';

import '../services/diary_controller.dart';

/// Manages trusted baselines without opening or modifying the exported files.
class WorkbookExportHistoryScreen extends StatefulWidget {
  const WorkbookExportHistoryScreen({
    super.key,
    required this.controller,
    required this.tr,
  });

  final DiaryController controller;
  final String Function(String) tr;

  @override
  State<WorkbookExportHistoryScreen> createState() =>
      _WorkbookExportHistoryScreenState();
}

class _WorkbookExportHistoryScreenState
    extends State<WorkbookExportHistoryScreen> {
  bool deleting = false;

  String t(String value) => widget.tr(value);

  String exportDate(Map<String, dynamic> item) {
    final raw = '${item['createdAt'] ?? ''}';
    final date = DateTime.tryParse(raw);
    if (date == null) return raw;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  String exportId(Map<String, dynamic> item, {bool short = false}) {
    final id = '${item['id'] ?? ''}';
    return short && id.length > 12 ? id.substring(0, 12) : id;
  }

  String counts(Map<String, dynamic> item) =>
      '${t('Transactions')}: ${item['entryCount']} • '
      '${t('Balance snapshots')}: ${item['snapshotCount']} • '
      '${t('Debts')}: ${item['debtCount']}';

  Future<void> confirmDelete(Map<String, dynamic> item) async {
    if (deleting) return;
    if (widget.controller.lastSaveError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Save pending changes before continuing.'))),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Delete export history?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(exportDate(item)),
            Text('${t('Export ID')}: ${exportId(item)}'),
            Text(counts(item)),
            const SizedBox(height: 12),
            Text(
              t(
                'The associated workbook can no longer be reimported. Your diary entries and exported file will not be deleted.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => deleting = true);
    try {
      await widget.controller.deleteWorkbookExportManifest(
        '${item['id']}',
        expectedGeneration: item['generation'] as int,
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.lastSaveError != null
                  ? t('Could not save export history. Retry the pending save.')
                  : t('Export history changed. Review it again.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('Workbook export history'))),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final exports = widget.controller.workbookExportHistory.reversed
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                t(
                  'Export history is kept in your encrypted diary and backups. Keeping more exports increases their size.',
                ),
              ),
            ),
            if (exports.isEmpty)
              Expanded(child: Center(child: Text(t('No saved exports yet'))))
            else
              Expanded(
                child: ListView.builder(
                  itemCount: exports.length,
                  itemBuilder: (context, index) {
                    final item = exports[index];
                    return Card(
                      child: ListTile(
                        title: Text(exportDate(item)),
                        subtitle: Text(
                          '${t('Export ID')}: ${exportId(item, short: true)}\n${counts(item)}',
                        ),
                        trailing: IconButton(
                          tooltip: t('Delete'),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: deleting
                              ? null
                              : () => confirmDelete(item),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    ),
  );
}
