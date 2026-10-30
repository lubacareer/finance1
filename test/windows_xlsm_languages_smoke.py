"""Opt-in desktop Excel check for app-generated synthetic language fixtures.

Set FINANCE_LOCALE_XLSM_DIR to a disposable directory, generate fixtures with
test/xlsm_localization_test.dart, then run this script with pywin32. The files
are opened read-only, never saved, and must not contain personal data.
"""
import os
from pathlib import Path

import win32com.client


fixtures = Path(os.environ['FINANCE_LOCALE_XLSM_DIR'])
labels = {
    'en': {
        'transactions': '_transactions', 'snapshots': '_snapshots',
        'debts': '_debts', 'instructions': '_instructions',
        'description': 'description', 'actual': 'actual',
        'planned': 'planned', 'pending': 'pending', 'transaction': 'transaction',
        'cash': 'cash', 'owed': 'owed', 'open': 'open',
        'income': 'Total income (actual)', 'expense': 'Total expenses (actual)',
        'missing': 'Missing ILS conversions (actual)',
    },
    'he': {
        'transactions': 'תנועות', 'snapshots': 'יתרות', 'debts': 'חובות',
        'instructions': 'הוראות', 'description': 'תיאור',
        'actual': 'בפועל', 'planned': 'מתוכנן', 'pending': 'בהמתנה',
        'transaction': 'תנועה', 'cash': 'מזומן', 'owed': 'אני חייב',
        'open': 'פתוח', 'income': 'סך הכנסות בפועל',
        'expense': 'סך הוצאות בפועל', 'missing': 'המרות לשקלים חסרות בפועל',
    },
    'ru': {
        'transactions': 'Операции', 'snapshots': 'Остатки', 'debts': 'Долги',
        'instructions': 'Инструкции', 'description': 'Описание',
        'actual': 'Факт', 'planned': 'Запланировано',
        'pending': 'Ожидает обработки', 'transaction': 'Операция',
        'cash': 'Наличные', 'owed': 'Я должен', 'open': 'Открыт',
        'income': 'Всего доходов (факт)', 'expense': 'Всего расходов (факт)',
        'missing': 'Нет пересчёта в ILS (факт)',
    },
}

excel = win32com.client.DispatchEx('Excel.Application')
excel.Visible = False
excel.DisplayAlerts = False
book = None
try:
    for language, expected in labels.items():
        path = fixtures / f'{language}.xlsm'
        if not path.is_file():
            raise FileNotFoundError(f'Missing synthetic fixture: {path}')
        book = excel.Workbooks.Open(str(path.resolve()), ReadOnly=True)
        transactions = book.Worksheets(expected['transactions'])
        book.Worksheets(expected['snapshots'])
        book.Worksheets(expected['debts'])
        instructions = book.Worksheets(expected['instructions'])
        month = book.Worksheets('2026-01')

        def refresh():
            excel.Run("'" + book.Name.replace("'", "''") + "'!RefreshSummaries")

        def footer(first_row, income, expense, missing):
            assert month.Cells(first_row, 1).Value == expected['income']
            assert month.Cells(first_row + 1, 1).Value == expected['expense']
            assert month.Cells(first_row + 2, 1).Value == expected['missing']
            assert month.Cells(first_row, 6).Value == income
            assert month.Cells(first_row + 1, 6).Value == expense
            assert month.Cells(first_row + 2, 6).Value == missing

        assert month.DisplayRightToLeft == (language == 'he')
        assert transactions.Range('D1').Value == expected['description']
        assert transactions.Range('D2').Value == 'Кофе קפה'
        assert transactions.Range('D3').Value == '=literal'
        assert not transactions.Range('D3').HasFormula
        assert month.Range('C15').Value == 'Кофе קפה'
        assert month.Range('E15').Value == expected['actual']
        assert month.Range('E18').Value == expected['pending']
        assert month.Range('J15').Value == expected['transaction']
        assert month.Range('L15').Value == expected['cash']
        assert month.Range('U15').Value == 'Лена'
        assert month.Range('V15').Value == expected['owed']
        assert month.Range('AB15').Value == expected['open']
        footer(22, 100, 20, 1)
        refresh()
        assert month.Range('B2').Value == 1
        assert month.Range('C15').Value == 'Кофе קפה'
        assert month.Range('C16').Value == '=literal'
        assert not month.Range('C16').HasFormula
        assert month.Range('E15').Value == expected['actual']
        assert month.Range('E18').Value == expected['pending']
        assert month.Range('L15').Value == expected['cash']
        assert month.Range('V15').Value == expected['owed']
        footer(22, 100, 20, 1)

        # A localized edited status must affect both the view and totals.
        transactions.Range('G2').Value = expected['planned']
        refresh()
        assert month.Range('E15').Value == expected['planned']
        assert month.Range('B9').Value == 0
        assert month.Range('B10').Value == 150
        footer(22, 0, 20, 1)
        transactions.Range('G2').Value = ' ' + expected['planned'] + ' '
        refresh()
        assert month.Range('E15').Value == expected['planned']
        assert month.Range('B9').Value == 0
        assert month.Range('B10').Value == 150
        footer(22, 0, 20, 1)
        transactions.Range('G2').Value = expected['actual']

        # A new row shifts the footer, rather than overwriting transaction data.
        transactions.Range('C8').Value = 46023  # 2026-01-01
        transactions.Range('D8').Value = 'New synthetic'
        transactions.Range('F8').Value = expected['transaction']
        transactions.Range('G8').Value = expected['actual']
        transactions.Range('I8').Value = -9
        transactions.Range('J8').Value = 'ILS'
        refresh()
        assert month.Range('C21').Value == 'New synthetic'
        assert month.Range('E21').Value == expected['actual']
        footer(23, 100, 29, 1)

        transactions.Range('G2').Value = 'invalid synthetic status'
        refresh()
        assert month.Range('B2').Value == 0
        assert month.Range('A3').Value == instructions.Range('A11').Value
        assert excel.ScreenUpdating
        book.Close(False)
        book = None
    print('English, Hebrew and Russian Excel checks passed')
finally:
    if book is not None:
        book.Close(False)
    excel.Quit()
