"""Opt-in Excel integration test; use the synthetic export test's output.

Set FINANCE_TEST_XLSM_PATH to a disposable path, run xlsm_export_test.dart,
then run this script on Windows with pywin32 and desktop Excel installed.
The workbook is opened without saving, and its macros must be enabled.
"""
import os

import win32com.client


path = os.environ['FINANCE_TEST_XLSM_PATH']
excel = win32com.client.DispatchEx('Excel.Application')
excel.Visible = False
excel.DisplayAlerts = False
excel.AutomationSecurity = 1
book = None
try:
    book = excel.Workbooks.Open(path)
    sheet = book.Worksheets('2026-01')
    transactions = book.Worksheets('_transactions')

    def refresh():
        excel.Run("'" + book.Name.replace("'", "''") + "'!RefreshSummaries")

    assert sheet.Buttons().Count == 3
    assert [sheet.Buttons(i).OnAction for i in range(1, 4)] == [
        'RefreshSummaries', 'PreviousMonth', 'NextMonth'
    ]
    transactions.Range('C4').Value = 46023  # 2026-01-01
    transactions.Range('D4').Value = 'Synthetic new expense'
    transactions.Range('I4').Value = -5
    transactions.Range('J4').Value = 'ILS'
    refresh()
    assert sheet.Range('B2').Value == 1
    assert sheet.Range('B9').Value == 30
    assert sheet.Range('C9').Value == 5
    assert sheet.Range('X15').Value == 'Food'
    assert transactions.Range('W4').Value is True
    transactions.Range('W4').Value = False
    refresh()
    assert sheet.Range('C9').Value == 0
    transactions.Range('W4').ClearContents()
    transactions.Range('V4').Value = '["ambiguous"]'
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'unverified links' in sheet.Range('A3').Value
    transactions.Range('V4').ClearContents()
    transactions.Range('C4').Value = 50000  # Outside the exported years.
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'outside the exported years' in sheet.Range('A3').Value
    transactions.Range('C4').ClearContents()
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    transactions.Range('C4').Value = 'not-a-date'
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    transactions.Range('C4').Value = 46023
    snapshots = book.Worksheets('_snapshots')
    snapshots.Range('E2').ClearContents()
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    snapshots.Range('E2').Value = 46034
    debts = book.Worksheets('_debts')
    debts.Range('F2').Value = 'not-a-date'
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    debts.Range('F2').Value = 46024
    transactions.Range('D10').Value = 'A trailing undated row'
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    transactions.Range('D10').ClearContents()
    payments = book.Worksheets('_debt_payments')
    payments.Range('C2').ClearContents()
    refresh()
    assert sheet.Range('B2').Value == 0
    assert 'missing or invalid date' in sheet.Range('A3').Value
    print('Excel XLSM smoke test passed')
finally:
    if book is not None:
        book.Close(False)
    excel.Quit()
