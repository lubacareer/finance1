import 'package:flutter/material.dart';

import '../services/insights.dart';

/// A forecast is derived locally; accepting a suggestion is an explicit action.
class ForecastScreen extends StatelessWidget {
  const ForecastScreen({
    super.key,
    required this.rows,
    required this.accounts,
    required this.onAccept,
    required this.onDismiss,
    required this.tr,
    this.dismissedIds = const [],
    this.rateCache = const {},
    this.onLink,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> accounts;
  final ValueChanged<Map<String, dynamic>> onAccept;
  final ValueChanged<Map<String, dynamic>> onDismiss;
  final String Function(String) tr;
  final List<String> dismissedIds;
  final Map<String, dynamic> rateCache;
  final ValueChanged<Map<String, dynamic>>? onLink;

  String _money(num value) => value.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final predictions = Insights.recurringPredictions(rows)
        .where((row) => !dismissedIds.contains(row['id']))
        .toList();
    final exchangeRates = ExchangeRates(rateCache);
    for (final row in predictions) {
      final currency = '${row['currency'] ?? 'ILS'}';
      if (currency != 'ILS') {
        final quote = exchangeRates.cached(currency, DateTime.now());
        if (quote != null) {
          row['amountIls'] = (row['amount'] as num) * (quote['rate'] as num);
          row['rateDate'] = quote['date'];
          row['rateSource'] = quote['source'];
        }
      }
    }
    final category = Insights.categoryForecast(rows);
    final monthly = Map<String, double>.from(category['monthly'] as Map);
    final future = [...rows, ...predictions];
    final matches = Insights.matchCandidates(rows, accounts: accounts);
    final names = {for (final a in accounts) '${a['id']}': '${a['name']}'};
    final byId = {for (final row in rows) '${row['id']}': row};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          tr('Three-month forecast'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(tr('Estimates are based on past transactions and may change.')),
        const SizedBox(height: 20),
        Text(
          tr('Recurring suggestions'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (predictions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr(
                'No recurring suggestions yet. At least three months of matching history are needed.',
              ),
            ),
          ),
        for (final row in predictions)
          Card(
            child: ListTile(
              title: Text('${row['description']}'),
              subtitle: Text(
                '${row['date']} • ${names['${row['accountId']}'] ?? ''} • ${tr('Predicted')}',
              ),
              trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${_money(row['amount'] as num)} ${row['currency']}'),
                  IconButton(
                    tooltip: tr('Accept'),
                    onPressed: () => onAccept(row),
                    icon: const Icon(Icons.check),
                  ),
                  IconButton(
                    tooltip: tr('Dismiss'),
                    onPressed: () => onDismiss(row),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text(
          tr('Estimated monthly spending by category'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (category['insufficientHistory'] == true)
          Text(
            tr(
              'There is not yet three full months of spending history. Estimates may be incomplete.',
            ),
          ),
        if ((category['missingRates'] as int) > 0)
          Text(
            tr(
              'Some transactions are excluded because an ILS rate is missing.',
            ),
          ),
        if (monthly.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(tr('No spending history available.')),
          ),
        for (final entry in monthly.entries)
          ListTile(
            dense: true,
            title: Text(entry.key),
            trailing: Text('₪ ${_money(entry.value)} / ${tr('month')}'),
          ),
        const SizedBox(height: 20),
        Text(
          tr('Projected balances'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final account in accounts.where((a) => a['type'] == 'bank'))
          Builder(
            builder: (context) {
              final projection = Insights.balanceProjection(account, future);
              final hasBalance = projection['hasStartingBalance'] == true;
              return ListTile(
                title: Text('${account['name']}'),
                subtitle: Text(
                  hasBalance
                      ? '${tr('Based on starting balance and planned or predicted entries.')}${(projection['missingRates'] as int) > 0 ? '\n${tr('Some transactions are excluded because an ILS rate is missing.')}' : ''}'
                      : tr('Set a current balance to project this account.'),
                ),
                trailing: hasBalance
                    ? Text('₪ ${_money(projection['balance'] as num)}')
                    : null,
              );
            },
          ),
        if (onLink != null && matches.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            tr('Possible duplicate or card payment'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            tr('Review these suggestions before linking or removing anything.'),
          ),
          for (final match in matches)
            if (byId['${match['firstId']}'] != null &&
                byId['${match['secondId']}'] != null)
              Card(
                child: ListTile(
                  title: Text(
                    '${byId['${match['firstId']}']!['description']} / ${byId['${match['secondId']}']!['description']}',
                  ),
                  subtitle: Text(
                    tr(
                      match['type'] == 'duplicate'
                          ? 'Possible duplicate'
                          : match['type'] == 'summary_purchases'
                          ? 'Possible matching card purchases'
                          : 'Possible card payment',
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: () => onLink!(match),
                    child: Text(tr('Review')),
                  ),
                ),
              ),
        ],
      ],
    );
  }
}
