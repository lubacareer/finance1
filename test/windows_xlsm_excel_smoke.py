"""Opt-in Excel integration test; use the synthetic export test's output.

Set FINANCE_TEST_XLSM_PATH to a disposable path, run xlsm_export_test.dart,
then run this script on Windows with pywin32 and desktop Excel installed.
The workbook is opened without saving, and its macros must be enabled.
"""
import datetime
import os

import win32com.client


path = os.environ['FINANCE_TEST_XLSM_PATH']
excel = win32com.client.DispatchEx('Excel.Application')
excel.Visible = False
excel.DisplayAlerts = False
book = None
try:
    book = excel.Workbooks.Open(path, ReadOnly=True)
    sheet = book.Worksheets('2026-01')
    transactions = book.Worksheets('_transactions')

    def refresh():
        excel.Run("'" + book.Name.replace("'", "''") + "'!RefreshSummaries")

    assert sheet.Buttons().Count == 3
    assert [sheet.Buttons(i).OnAction for i in range(1, 4)] == [
        'RefreshSummaries', 'PreviousMonth', 'NextMonth'
    ]
    # Initial values are visible before any macro runs.
    assert sheet.Range('C15').Value == 'Cafe'
    assert sheet.Range('F15').Value == 30
    assert sheet.Range('N15').Value == 'Cash'
    assert sheet.Range('U15').Value == 'Alice'
    assert sheet.Range('Y15').Value == 6
    assert sheet.Range('B9').Value == 30
    empty = book.Worksheets('2026-03')
    assert empty.Range('A15').Value == 'No transactions'
    assert empty.Range('K15').Value == 'No balance snapshots'
    assert empty.Range('U15').Value == 'No debts'
    # Empty-section labels must be replaced by real dates on a later refresh.
    transactions.Range('C4').Value = 46082  # 2026-03-01
    transactions.Range('D4').Value = 'March purchase'
    transactions.Range('I4').Value = -10
    transactions.Range('J4').Value = 'ILS'
    snapshots = book.Worksheets('_snapshots')
    snapshots.Range('A3').Value = 'new-snapshot'
    snapshots.Range('D3').Value = 'March cash'
    snapshots.Range('E3').Value = 46082
    refresh()
    assert isinstance(empty.Range('A15').Value, datetime.datetime)
    assert isinstance(empty.Range('K15').Value, datetime.datetime)
    assert empty.Range('C15').Value == 'March purchase'
    assert empty.Range('N15').Value == 'March cash'
    transactions.Range('A4:AA4').ClearContents()
    snapshots.Range('A3:L3').ClearContents()
    transactions.Range('C4').Value = 46023  # 2026-01-01
    transactions.Range('D4').Value = 'Synthetic new expense'
    transactions.Range('I4').Value = -5
    transactions.Range('J4').Value = 'ILS'
    refresh()
    assert sheet.Range('B2').Value == 1
    assert sheet.Range('B9').Value == 30
    assert sheet.Range('C9').Value == 5
    assert sheet.Range('D15').Value == 'Food'
    assert sheet.Range('C16').Value == 'Synthetic new expense'
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
    # Formula-empty ILS conversions count by month and status, for both signs.
    for index, date, amount, status, pending in [
        (5, 46024, 10, 'actual', False),
        (6, 46024, -11, 'actual', False),
        (7, 46024, -12, 'planned', False),
        (8, 46024, 13, 'planned', True),
        (9, 46054, -14, 'actual', False),  # February 2026
        (10, 46024, 0, 'actual', False),
        (11, 46024, 15, 'actual', False),
    ]:
        transactions.Cells(index, 3).Value = date
        transactions.Cells(index, 4).Value = 'Synthetic foreign transaction'
        transactions.Cells(index, 7).Value = status
        transactions.Cells(index, 8).Value = pending
        transactions.Cells(index, 9).Value = amount
        transactions.Cells(index, 10).Value = 'USD'
    transactions.Cells(11, 11).Value = 55  # Known conversion.
    refresh()
    assert sheet.Range('E9').Value == 2
    assert sheet.Range('E10').Value == 1
    assert sheet.Range('E11').Value == 1
    assert sheet.Range('E12').Value == 0
    assert book.Worksheets('2026-02').Range('E9').Value == 1
    transactions.Range('A5:AA11').ClearContents()
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
