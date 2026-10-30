Option Explicit

Private Sub CopyLiteral(ByVal target As Range, ByVal value As Variant)
    target.NumberFormat = "@"
    target.Value2 = CStr(value)
End Sub

Private Function IsWorkbookDate(ByVal value As Variant) As Boolean
    If IsEmpty(value) Or IsError(value) Then Exit Function
    If IsDate(value) Then
        IsWorkbookDate = True
    ElseIf IsNumeric(value) Then
        IsWorkbookDate = (CDbl(value) >= 1 And CDbl(value) <= 2958465)
    End If
End Function

Private Function HasMonth(ByVal value As Variant) As Boolean
    Dim candidate As Worksheet
    On Error Resume Next
    Set candidate = ThisWorkbook.Worksheets(Format(value, "yyyy-mm"))
    On Error GoTo 0
    HasMonth = Not candidate Is Nothing
End Function

Public Sub RefreshSummaries()
    Dim sheet As Worksheet, transactions As Worksheet
    Dim snapshots As Worksheet, debts As Worksheet, payments As Worksheet
    Dim lastRow As Long, row As Long, out As Long, payRow As Long
    Dim targetMonth As String, paymentTotal As Double, clearLast As Long
    Dim warningMessage As String, source As Variant, dateColumn As Long, endRow As Long, links As String
    Dim lastColumn As Long, found As Range
    On Error GoTo Failed
    Set transactions = ThisWorkbook.Worksheets("_transactions")
    Set snapshots = ThisWorkbook.Worksheets("_snapshots")
    Set debts = ThisWorkbook.Worksheets("_debts")
    Set payments = ThisWorkbook.Worksheets("_debt_payments")
    Application.ScreenUpdating = False
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then sheet.Range("B2").Value = 0
    Next sheet
    lastRow = Application.Max(2, transactions.Cells(transactions.Rows.Count, "A").End(xlUp).Row, transactions.Cells(transactions.Rows.Count, "C").End(xlUp).Row, transactions.Cells(transactions.Rows.Count, "D").End(xlUp).Row)
    For Each source In Array(transactions, snapshots, debts, payments)
        Select Case source.Name
            Case "_transactions": dateColumn = 3: lastColumn = 24
            Case "_snapshots": dateColumn = 5: lastColumn = 11
            Case "_debt_payments": dateColumn = 3: lastColumn = 4
            Case Else: dateColumn = 6: lastColumn = 10
        End Select
        Set found = source.Range(source.Cells(1, 1), source.Cells(source.Rows.Count, lastColumn)).Find(What:="*", LookIn:=xlValues, LookAt:=xlPart, SearchOrder:=xlByRows, SearchDirection:=xlPrevious, MatchCase:=False, SearchFormat:=False)
        endRow = 1
        If Not found Is Nothing Then endRow = found.Row
        For row = 2 To endRow
            If Application.CountA(source.Range(source.Cells(row, 1), source.Cells(row, lastColumn))) > 0 Then
                If Not IsWorkbookDate(source.Cells(row, dateColumn).Value) Then
                    warningMessage = ThisWorkbook.Worksheets("_instructions").Range("A7").Value
                    GoTo ReviewNeeded
                End If
                If source.Name <> "_debt_payments" And Not HasMonth(source.Cells(row, dateColumn).Value) Then
                    warningMessage = ThisWorkbook.Worksheets("_instructions").Range("A5").Value
                    GoTo ReviewNeeded
                End If
            End If
        Next row
    Next source
    For row = 2 To lastRow
        If IsWorkbookDate(transactions.Cells(row, 3).Value) Then
            If IsEmpty(transactions.Cells(row, 23).Value) Or transactions.Cells(row, 23).Value = "" Then
                links = Trim(CStr(transactions.Cells(row, 22).Value))
                If Len(Trim(CStr(transactions.Cells(row, 1).Value))) > 0 Or (links <> "" And links <> "[]") Then
                    warningMessage = ThisWorkbook.Worksheets("_instructions").Range("A6").Value
                    GoTo ReviewNeeded
                End If
            End If
        End If
    Next row
    For row = 2 To lastRow
        If IsWorkbookDate(transactions.Cells(row, 3).Value) Then
            If IsEmpty(transactions.Cells(row, 23).Value) Or transactions.Cells(row, 23).Value = "" Then transactions.Cells(row, 23).Value = True
        End If
    Next row
    If lastRow >= 2 Then
        transactions.Range("Y2:Y" & lastRow).FormulaR1C1 = "=IF(RC[-15]=""ILS"",RC[-16],IF(ISNUMBER(RC[-14]),RC[-14],""""))"
        transactions.Range("Z2:Z" & lastRow).FormulaR1C1 = "=IF(AND(RC[-19]=""planned"",RC[-18]=TRUE),""pending"",IF(RC[-19]="""",""actual"",RC[-19]))"
    End If
    transactions.Calculate
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then
            targetMonth = sheet.Name
            sheet.Range("B1").Value = lastRow
            clearLast = Application.Max(15, sheet.Cells(sheet.Rows.Count, "A").End(xlUp).Row, sheet.Cells(sheet.Rows.Count, "K").End(xlUp).Row, sheet.Cells(sheet.Rows.Count, "U").End(xlUp).Row)
            sheet.Range("A15:AD" & clearLast).ClearContents
            out = 15
            For row = 2 To lastRow
                If IsWorkbookDate(transactions.Cells(row, 3).Value) Then
                    If Format(transactions.Cells(row, 3).Value, "yyyy-mm") = targetMonth Then
                        sheet.Cells(out, 21).Value = transactions.Cells(row, 3).Value
                        sheet.Cells(out, 21).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 22), transactions.Cells(row, 24).Value
                        CopyLiteral sheet.Cells(out, 23), transactions.Cells(row, 4).Value
                        CopyLiteral sheet.Cells(out, 24), transactions.Cells(row, 5).Value
                        CopyLiteral sheet.Cells(out, 25), transactions.Cells(row, 26).Value
                        sheet.Cells(out, 26).Value = transactions.Cells(row, 9).Value
                        CopyLiteral sheet.Cells(out, 27), transactions.Cells(row, 10).Value
                        sheet.Cells(out, 28).Value = transactions.Cells(row, 25).Value
                        sheet.Cells(out, 29).Value = transactions.Cells(row, 23).Value
                        CopyLiteral sheet.Cells(out, 30), transactions.Cells(row, 6).Value
                        out = out + 1
                    End If
                End If
            Next row
            out = 15
            For row = 2 To snapshots.Cells(snapshots.Rows.Count, "A").End(xlUp).Row
                If IsWorkbookDate(snapshots.Cells(row, 5).Value) Then
                    If Format(snapshots.Cells(row, 5).Value, "yyyy-mm") = targetMonth Then
                        sheet.Cells(out, 1).Value = snapshots.Cells(row, 5).Value
                        sheet.Cells(out, 1).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 2), snapshots.Cells(row, 2).Value
                        CopyLiteral sheet.Cells(out, 3), snapshots.Cells(row, 12).Value
                        CopyLiteral sheet.Cells(out, 4), snapshots.Cells(row, 4).Value
                        sheet.Cells(out, 5).Value = snapshots.Cells(row, 6).Value
                        sheet.Cells(out, 6).Value = snapshots.Cells(row, 7).Value
                        sheet.Cells(out, 7).Value = snapshots.Cells(row, 8).Value
                        sheet.Cells(out, 8).Value = snapshots.Cells(row, 9).Value
                        If IsNumeric(snapshots.Cells(row, 10).Value) And Not IsEmpty(snapshots.Cells(row, 10).Value) Then
                            sheet.Cells(out, 9).Value = snapshots.Cells(row, 10).Value
                        ElseIf IsNumeric(snapshots.Cells(row, 6).Value) And Not IsEmpty(snapshots.Cells(row, 6).Value) And IsNumeric(snapshots.Cells(row, 8).Value) And Not IsEmpty(snapshots.Cells(row, 8).Value) Then
                            sheet.Cells(out, 9).Value = snapshots.Cells(row, 6).Value - snapshots.Cells(row, 8).Value
                        End If
                        CopyLiteral sheet.Cells(out, 10), snapshots.Cells(row, 11).Value
                        out = out + 1
                    End If
                End If
            Next row
            out = 15
            For row = 2 To debts.Cells(debts.Rows.Count, "A").End(xlUp).Row
                If IsWorkbookDate(debts.Cells(row, 6).Value) Then
                    If Format(debts.Cells(row, 6).Value, "yyyy-mm") = targetMonth Then
                        paymentTotal = 0
                        For payRow = 2 To payments.Cells(payments.Rows.Count, "B").End(xlUp).Row
                            If payments.Cells(payRow, 2).Value = debts.Cells(row, 1).Value And IsNumeric(payments.Cells(payRow, 4).Value) Then
                                paymentTotal = paymentTotal + payments.Cells(payRow, 4).Value
                            End If
                        Next payRow
                        CopyLiteral sheet.Cells(out, 11), debts.Cells(row, 2).Value
                        CopyLiteral sheet.Cells(out, 12), debts.Cells(row, 3).Value
                        sheet.Cells(out, 13).Value = debts.Cells(row, 4).Value
                        sheet.Cells(out, 14).Value = paymentTotal
                        If IsNumeric(debts.Cells(row, 5).Value) And Not IsEmpty(debts.Cells(row, 5).Value) Then
                            sheet.Cells(out, 15).Value = debts.Cells(row, 5).Value
                        ElseIf IsNumeric(debts.Cells(row, 4).Value) And Not IsEmpty(debts.Cells(row, 4).Value) Then
                            sheet.Cells(out, 15).Value = debts.Cells(row, 4).Value - paymentTotal
                        End If
                        sheet.Cells(out, 16).Value = debts.Cells(row, 6).Value
                        sheet.Cells(out, 17).Value = debts.Cells(row, 7).Value
                        sheet.Cells(out, 16).NumberFormat = "yyyy-mm-dd"
                        sheet.Cells(out, 17).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 18), debts.Cells(row, 8).Value
                        CopyLiteral sheet.Cells(out, 19), debts.Cells(row, 10).Value
                        out = out + 1
                    End If
                End If
            Next row
            sheet.Range("B2").Value = 1
            sheet.Range("A3").Value = sheet.Range("A4").Value
        End If
    Next sheet
    Application.CalculateFull
    Application.ScreenUpdating = True
    Exit Sub
ReviewNeeded:
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then sheet.Range("A3").Value = warningMessage
    Next sheet
    Application.ScreenUpdating = True
    Exit Sub
Failed:
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then
            sheet.Range("B2").Value = 0
            sheet.Range("A3").Value = "Refresh failed; check workbook data."
        End If
    Next sheet
    Application.ScreenUpdating = True
    MsgBox ThisWorkbook.Worksheets("_instructions").Range("A4").Value, vbExclamation
End Sub

Public Sub NextMonth()
    Dim sheet As Worksheet, firstMonth As Worksheet, foundCurrent As Boolean
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then
            If firstMonth Is Nothing Then Set firstMonth = sheet
            If foundCurrent Then
                sheet.Activate
                Exit Sub
            End If
            If sheet.Name = ActiveSheet.Name Then foundCurrent = True
        End If
    Next sheet
    If Not firstMonth Is Nothing Then firstMonth.Activate
End Sub

Public Sub PreviousMonth()
    Dim sheet As Worksheet, previous As Worksheet, lastMonth As Worksheet
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then
            If sheet.Name = ActiveSheet.Name Then
                If Not previous Is Nothing Then
                    previous.Activate
                    Exit Sub
                End If
            End If
            Set previous = sheet
            Set lastMonth = sheet
        End If
    Next sheet
    If Not lastMonth Is Nothing Then lastMonth.Activate
End Sub
