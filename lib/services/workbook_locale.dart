/// Workbook-visible labels are defined independently from user-provided data.
/// English names and values deliberately retain the original workbook schema.
const workbookLocaleSheet = '_locale';
const workbookLocaleMarker = 'financial-diary-workbook-locale-v1';
const workbookLanguages = <String>['en', 'he', 'ru'];

const workbookLocalizedSheets = <String>[
  '_transactions',
  '_snapshots',
  '_debts',
  '_debt_payments',
  '_instructions',
  '_column_guide',
];

const _sheetNames = <String, Map<String, String>>{
  'he': {
    '_transactions': 'תנועות',
    '_snapshots': 'יתרות',
    '_debts': 'חובות',
    '_debt_payments': 'תשלומי חוב',
    '_instructions': 'הוראות',
    '_column_guide': 'מדריך עמודות',
  },
  'ru': {
    '_transactions': 'Операции',
    '_snapshots': 'Остатки',
    '_debts': 'Долги',
    '_debt_payments': 'Платежи по долгам',
    '_instructions': 'Инструкции',
    '_column_guide': 'Описание столбцов',
  },
};

const workbookFieldLabels = <String, String>{
  'id': 'Record ID',
  'accountId': 'Account ID',
  'date': 'Date',
  'description': 'Description',
  'category': 'Category',
  'kind': 'Entry type',
  'status': 'Status',
  'pending': 'Pending',
  'amount': 'Amount',
  'currency': 'Currency',
  'amountIls': 'ILS amount',
  'rate': 'Exchange rate',
  'rateDate': 'Rate date',
  'rateSource': 'Rate source',
  'billingDate': 'Billing date',
  'cardProvider': 'Card provider',
  'cardSuffix': 'Card identifier',
  'repeatMonthly': 'Repeat monthly',
  'recurringSourceId': 'Recurring source ID',
  'recurringOffset': 'Recurring offset',
  'recurringScheduleDate': 'Recurring schedule date',
  'recurringOverridden': 'Recurring override',
  'linkedIds': 'Linked transaction IDs',
  'countsTowardSpending': 'Counts toward spending',
  'accountName': 'Account',
  'effectiveIls': 'Effective ILS amount',
  'summaryStatus': 'Summary status',
  'name': 'Name',
  'remainingBalance': 'Remaining balance',
  'fromBank': 'From bank',
  'payments': 'Payments',
  'otherBalance': 'Other balance',
  'debt': 'Debt',
  'person': 'Person',
  'direction': 'Direction',
  'originalAmount': 'Original amount',
  'dueDate': 'Due date',
  'debtId': 'Debt ID',
};

/// Stable v1 labels are part of the reimport format. Do not change them when
/// updating UI translations; add a new format version and decoder instead.
const _headersV1 = <String, Map<String, String>>{
  'he': {
    'id': 'מזהה רשומה',
    'accountId': 'מזהה חשבון',
    'date': 'תאריך',
    'description': 'תיאור',
    'category': 'קטגוריה',
    'kind': 'סוג תנועה',
    'status': 'סטטוס',
    'pending': 'בהמתנה',
    'amount': 'סכום',
    'currency': 'מטבע',
    'amountIls': 'סכום בשקלים',
    'rate': 'שער חליפין',
    'rateDate': 'תאריך שער',
    'rateSource': 'מקור השער',
    'billingDate': 'תאריך חיוב',
    'cardProvider': 'חברת הכרטיס',
    'cardSuffix': 'מזהה כרטיס',
    'repeatMonthly': 'חזרה חודשית',
    'recurringSourceId': 'מזהה מקור לחזרה',
    'recurringOffset': 'היסט חזרה',
    'recurringScheduleDate': 'תאריך לוח החזרות',
    'recurringOverridden': 'שינוי ברשומה חוזרת',
    'linkedIds': 'מזהי תנועות מקושרות',
    'countsTowardSpending': 'נכלל בהוצאות',
    'accountName': 'חשבון',
    'effectiveIls': 'סכום מחושב בשקלים',
    'summaryStatus': 'סטטוס לסיכום',
    'name': 'שם',
    'remainingBalance': 'יתרה שנותרה',
    'fromBank': 'מהבנק',
    'payments': 'תשלומים',
    'otherBalance': 'יתרה נוספת',
    'debt': 'חוב',
    'person': 'אדם',
    'direction': 'כיוון',
    'originalAmount': 'סכום מקורי',
    'dueDate': 'תאריך פירעון',
    'debtId': 'מזהה חוב',
  },
  'ru': {
    'id': 'Идентификатор записи',
    'accountId': 'Идентификатор счёта',
    'date': 'Дата',
    'description': 'Описание',
    'category': 'Категория',
    'kind': 'Тип записи',
    'status': 'Статус',
    'pending': 'Ожидает обработки',
    'amount': 'Сумма',
    'currency': 'Валюта',
    'amountIls': 'Сумма в шекелях',
    'rate': 'Обменный курс',
    'rateDate': 'Дата курса',
    'rateSource': 'Источник курса',
    'billingDate': 'Дата списания',
    'cardProvider': 'Платёжная компания',
    'cardSuffix': 'Идентификатор карты',
    'repeatMonthly': 'Повторять ежемесячно',
    'recurringSourceId': 'Идентификатор источника повтора',
    'recurringOffset': 'Смещение повтора',
    'recurringScheduleDate': 'Дата расписания повтора',
    'recurringOverridden': 'Изменение повторной записи',
    'linkedIds': 'Идентификаторы связанных операций',
    'countsTowardSpending': 'Учитывается в расходах',
    'accountName': 'Счёт',
    'effectiveIls': 'Расчётная сумма в шекелях',
    'summaryStatus': 'Статус для сводки',
    'name': 'Название',
    'remainingBalance': 'Остаток',
    'fromBank': 'Из банка',
    'payments': 'Платежи',
    'otherBalance': 'Другой остаток',
    'debt': 'Долг',
    'person': 'Человек',
    'direction': 'Направление',
    'originalAmount': 'Первоначальная сумма',
    'dueDate': 'Срок оплаты',
    'debtId': 'Идентификатор долга',
  },
};

const _enumLabelsV1 = <String, Map<String, String>>{
  'he': {
    'entry.status:actual': 'בפועל',
    'entry.status:planned': 'מתוכנן',
    'entry.status:predicted': 'תחזית',
    'entry.status:pending': 'בהמתנה',
    'entry.kind:transaction': 'תנועה',
    'entry.kind:card_summary': 'סיכום חיוב כרטיס',
    'entry.kind:bank_payment': 'תשלום בנקאי',
    'snapshot.kind:account': 'חשבון',
    'snapshot.kind:cash': 'מזומן',
    'debt.direction:owed': 'אני חייב',
    'debt.direction:receivable': 'חייבים לי',
    'debt.status:open': 'פתוח',
    'debt.status:paid': 'שולם',
  },
  'ru': {
    'entry.status:actual': 'Факт',
    'entry.status:planned': 'Запланировано',
    'entry.status:predicted': 'Прогноз',
    'entry.status:pending': 'Ожидает обработки',
    'entry.kind:transaction': 'Операция',
    'entry.kind:card_summary': 'Сводный платёж по карте',
    'entry.kind:bank_payment': 'Банковский платёж',
    'snapshot.kind:account': 'Счёт',
    'snapshot.kind:cash': 'Наличные',
    'debt.direction:owed': 'Я должен',
    'debt.direction:receivable': 'Мне должны',
    'debt.status:open': 'Открыт',
    'debt.status:paid': 'Оплачен',
  },
};

/// Order is part of the `_locale` sheet format used by the Excel macro.
const workbookEnums = <(String, String, String)>[
  ('entry.status', 'actual', 'Actual'),
  ('entry.status', 'planned', 'Planned'),
  ('entry.status', 'predicted', 'Predicted'),
  ('entry.status', 'pending', 'Pending'),
  ('entry.kind', 'transaction', 'Transaction'),
  ('entry.kind', 'card_summary', 'Card charge summary'),
  ('entry.kind', 'bank_payment', 'Bank payment'),
  ('snapshot.kind', 'account', 'Account'),
  ('snapshot.kind', 'cash', 'Cash'),
  ('debt.direction', 'owed', 'I owe'),
  ('debt.direction', 'receivable', 'Owed to me'),
  ('debt.status', 'open', 'Open'),
  ('debt.status', 'paid', 'Paid'),
];

String workbookSheetName(String language, String name) =>
    _sheetNames[language]?[name] ?? name;

String workbookHeader(String language, String field) =>
    _headersV1[language]?[field] ?? field;

String workbookEnumLabel(String language, String group, String value) =>
    _enumLabelsV1[language]?['$group:$value'] ?? value;

String? workbookEnumCode(String language, String group, String value) {
  for (final item in workbookEnums) {
    if (item.$1 == group &&
        (item.$2 == value ||
            workbookEnumLabel(language, group, item.$2) == value)) {
      return item.$2;
    }
  }
  return null;
}

List<List<String>> workbookLocaleRows(String language) {
  if (!workbookLanguages.contains(language)) {
    throw ArgumentError.value(
      language,
      'language',
      'Unsupported workbook language',
    );
  }
  return [
    [workbookLocaleMarker, language],
    for (final sheet in workbookLocalizedSheets)
      [sheet, workbookSheetName(language, sheet)],
    <String>[],
    <String>[],
    for (final item in workbookEnums)
      [item.$1, item.$2, workbookEnumLabel(language, item.$1, item.$2)],
  ];
}
