import 'package:flutter/material.dart';

import '../services/card_identity.dart';
import '../services/diary_controller.dart';
import '../services/insights.dart';

/// Captures a single preview and submits that same snapshot for validation.
Future<void> showMoveCardAccountDialog(
  BuildContext context, {
  required DiaryController controller,
  required Map<String, dynamic> source,
  required String Function(String) tr,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _MoveCardAccountDialog(controller: controller, source: source, tr: tr),
);

class _MoveCardAccountDialog extends StatefulWidget {
  const _MoveCardAccountDialog({
    required this.controller,
    required this.source,
    required this.tr,
  });
  final DiaryController controller;
  final Map<String, dynamic> source;
  final String Function(String) tr;

  @override
  State<_MoveCardAccountDialog> createState() => _MoveCardAccountDialogState();
}

class _MoveCardAccountDialogState extends State<_MoveCardAccountDialog> {
  String? destination;
  Map<String, dynamic>? snapshot;
  final provider = TextEditingController();
  final suffix = TextEditingController();
  bool assign = false, saving = false;
  String? error;
  String t(String value) => widget.tr(value);

  @override
  void dispose() {
    provider.dispose();
    suffix.dispose();
    super.dispose();
  }

  void choose(String? value) {
    try {
      final nextSnapshot = value == null
          ? null
          : widget.controller.cardAccountMoveSnapshot(
              '${widget.source['id']}',
              value,
            );
      setState(() {
        destination = value;
        snapshot = nextSnapshot;
        error = null;
      });
    } on Object {
      setState(() {
        destination = null;
        snapshot = null;
        error = t(
          'The diary changed since this preview. Close and reopen the move to review again.',
        );
      });
    }
  }

  Future<void> submit() async {
    if (saving || destination == null || snapshot == null) return;
    final cleanProvider = provider.text.trim().toUpperCase();
    final cleanSuffix = suffix.text.trim();
    if (assign &&
        (cleanProvider.isEmpty || !RegExp(r'^\d{4}$').hasMatch(cleanSuffix))) {
      setState(() => error = t('Enter a provider and four-digit card suffix.'));
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.moveCardAccountEntries(
        '${widget.source['id']}',
        destination!,
        expectedSnapshot: snapshot!,
        assignProvider: assign ? cleanProvider : null,
        assignSuffix: assign ? cleanSuffix : null,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (failure) {
      if (!mounted) return;
      if (widget.controller.lastSaveError != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t('Changes not saved')),
            content: Text(
              t(
                'Move changes remain in memory but are not saved. Return to the diary and use Retry to save them.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('OK')),
              ),
            ],
          ),
        );
        if (mounted) Navigator.pop(context);
      } else {
        setState(
          () => error = t(
            failure is StateError &&
                    failure.message ==
                        'Conflicting saved card mappings require review.'
                ? 'Conflicting saved card mappings require review.'
                : 'The diary changed since this preview. Close and reopen the move to review again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = widget.controller.accounts
        .where((a) => a['type'] == 'card' && a['id'] != widget.source['id'])
        .toList();
    final data = snapshot;
    final rows = data == null
        ? <Map<String, dynamic>>[]
        : (data['entries'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
    final moved = rows
        .where((r) => r['accountId'] == widget.source['id'])
        .toList();
    final unidentified = moved.where((r) => cardIdentity(r) == null).length;
    final ids = moved.map((r) => '${r['id']}').toSet();
    final affected = data == null
        ? <Map<String, dynamic>>[]
        : (data['imports'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where(
                (batch) => ((batch['entryIds'] as List?) ?? []).any(
                  (id) => ids.contains('$id'),
                ),
              )
              .toList();
    final previewAccounts = data == null
        ? <Map<String, dynamic>>[]
        : (data['accounts'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
    final hypothetical = rows
        .map(
          (r) => r['accountId'] == widget.source['id']
              ? {...r, 'accountId': destination}
              : r,
        )
        .toList();
    String projection(
      Map<String, dynamic> account,
      List<Map<String, dynamic>> entries,
    ) {
      final value = Insights.balanceProjection(account, entries);
      final missing = value['missingRates'] as int;
      final balance = (value['balance'] as num).toStringAsFixed(2);
      return '${value['hasStartingBalance'] == true ? '₪ $balance' : t('Unknown')} ${missing == 0 ? '' : '(${t('Missing rate')}: $missing)'}';
    }

    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: Text(t('Move all transactions')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${t('From')}: ${widget.source['name']}'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: destination,
                  decoration: InputDecoration(
                    labelText: t('Destination account'),
                  ),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: '${a['id']}',
                        child: Text('${a['name']}'),
                      ),
                  ],
                  onChanged: saving ? null : choose,
                ),
                if (accounts.isEmpty)
                  Text(t('Create another credit card account first.')),
                if (data != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${t('Transactions')}: ${moved.length} • ${t('Unidentified card')}: $unidentified',
                  ),
                  Text('${t('Affected statements')}: ${affected.length}'),
                  for (final batch in affected)
                    Text('• ${batch['fileName'] ?? ''}'),
                  const SizedBox(height: 8),
                  Text(t('Opening balances stay in their original accounts.')),
                  for (final a in previewAccounts.where(
                    (a) =>
                        a['id'] == widget.source['id'] ||
                        a['id'] == destination,
                  ))
                    Text(
                      '${a['name']} • ${t('Account balance')}: ${a['balance'] is num ? '₪ ${(a['balance'] as num).toStringAsFixed(2)}' : t('Unknown')}',
                    ),
                  Text(
                    t(
                      'Three-month projected balances before and after the move:',
                    ),
                  ),
                  for (final a in previewAccounts.where(
                    (a) =>
                        a['id'] == widget.source['id'] ||
                        a['id'] == destination,
                  ))
                    Text(
                      '${a['name']}: ${projection(a, rows)} → ${projection(a, hypothetical)}',
                    ),
                  if (unidentified > 0) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: assign,
                      onChanged: saving
                          ? null
                          : (v) => setState(() => assign = v ?? false),
                      title: Text(
                        t('Assign a card to unidentified transactions'),
                      ),
                    ),
                    if (assign) ...[
                      TextField(
                        controller: provider,
                        decoration: InputDecoration(
                          labelText: t('Card provider'),
                        ),
                      ),
                      TextField(
                        controller: suffix,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        decoration: InputDecoration(
                          labelText: t('Last four card digits'),
                        ),
                      ),
                      Text(
                        t('Check the statement before assigning this card.'),
                      ),
                    ],
                  ],
                ],
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: saving || data == null || moved.isEmpty ? null : submit,
            child: Text(t('Move transactions')),
          ),
        ],
      ),
    );
  }
}
