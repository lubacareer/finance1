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

' The locale table contains display text, so the compiled macro need not
' embed text in a Windows-specific character encoding.
Private Function LocalizedSheet(ByVal locale As Worksheet, ByVal row As Long, ByVal legacyName As String) As Worksheet
    If locale Is Nothing Then
        Set LocalizedSheet = ThisWorkbook.Worksheets(legacyName)
    Else
        Set LocalizedSheet = ThisWorkbook.Worksheets(CStr(locale.Cells(row, 2).Value2))
    End If
End Function

Private Function ValidLabel(ByVal value As Variant, ByVal locale As Worksheet, ByVal firstRow As Long, ByVal lastRow As Long, ByVal allowBlank As Boolean) As Boolean
    Dim row As Long, candidate As String
    If IsError(value) Then Exit Function
    candidate = Trim$(CStr(value))
    If candidate = "" Then
        ValidLabel = allowBlank
        Exit Function
    End If
    If locale Is Nothing Then
        ValidLabel = True
        Exit Function
    End If
    For row = firstRow To lastRow
        If candidate = CStr(locale.Cells(row, 2).Value2) Or candidate = CStr(locale.Cells(row, 3).Value2) Then
            ValidLabel = True
            Exit Function
        End If
    Next row
End Function

Private Function DisplayStatus(ByVal locale As Worksheet, ByVal value As Variant) As String
    Dim row As Long
    DisplayStatus = CStr(value)
    If locale Is Nothing Then Exit Function
    For row = 10 To 13
        If CStr(value) = CStr(locale.Cells(row, 2).Value2) Then
            DisplayStatus = CStr(locale.Cells(row, 3).Value2)
            Exit Function
        End If
    Next row
End Function

Private Function DisplayLabel(ByVal locale As Worksheet, ByVal value As Variant, ByVal firstRow As Long, ByVal lastRow As Long) As String
    Dim row As Long, candidate As String
    candidate = Trim$(CStr(value))
    DisplayLabel = candidate
    If locale Is Nothing Then Exit Function
    For row = firstRow To lastRow
        If candidate = CStr(locale.Cells(row, 2).Value2) Or candidate = CStr(locale.Cells(row, 3).Value2) Then
            DisplayLabel = CStr(locale.Cells(row, 3).Value2)
            Exit Function
        End If
    Next row
End Function

Public Sub RefreshSummaries()
    Dim sheet As Worksheet, transactions As Worksheet
    Dim snapshots As Worksheet, debts As Worksheet, payments As Worksheet
    Dim lastRow As Long, row As Long, out As Long, payRow As Long
    Dim targetMonth As String, paymentTotal As Double, clearLast As Long
    Dim warningMessage As String, source As Variant, dateColumn As Long, endRow As Long, links As String
    Dim lastColumn As Long, found As Range
    Dim locale As Worksheet, instructions As Worksheet
    Dim previousScreenUpdating As Boolean
    previousScreenUpdating = Application.ScreenUpdating
    On Error GoTo Failed
    On Error Resume Next
    Set locale = ThisWorkbook.Worksheets("_locale")
    On Error GoTo Failed
    If Not locale Is Nothing Then
        If locale.Range("A1").Value2 <> "financial-diary-workbook-locale-v1" Then Err.Raise 5
    End If
    Set transactions = LocalizedSheet(locale, 2, "_transactions")
    Set snapshots = LocalizedSheet(locale, 3, "_snapshots")
    Set debts = LocalizedSheet(locale, 4, "_debts")
    Set payments = LocalizedSheet(locale, 5, "_debt_payments")
    Set instructions = LocalizedSheet(locale, 6, "_instructions")
    Application.ScreenUpdating = False
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then sheet.Range("B2").Value = 0
    Next sheet
    lastRow = Application.Max(2, transactions.Cells(transactions.Rows.Count, "A").End(xlUp).Row, transactions.Cells(transactions.Rows.Count, "C").End(xlUp).Row, transactions.Cells(transactions.Rows.Count, "D").End(xlUp).Row)
    For Each source In Array(transactions, snapshots, debts, payments)
        If source.Name = transactions.Name Then
            dateColumn = 3: lastColumn = 24
        ElseIf source.Name = snapshots.Name Then
            dateColumn = 5: lastColumn = 11
        ElseIf source.Name = payments.Name Then
            dateColumn = 3: lastColumn = 4
        Else
            dateColumn = 6: lastColumn = 10
        End If
        Set found = source.Range(source.Cells(1, 1), source.Cells(source.Rows.Count, lastColumn)).Find(What:="*", LookIn:=xlValues, LookAt:=xlPart, SearchOrder:=xlByRows, SearchDirection:=xlPrevious, MatchCase:=False, SearchFormat:=False)
        endRow = 1
        If Not found Is Nothing Then endRow = found.Row
        For row = 2 To endRow
            If Application.CountA(source.Range(source.Cells(row, 1), source.Cells(row, lastColumn))) > 0 Then
                If Not IsWorkbookDate(source.Cells(row, dateColumn).Value) Then
                    warningMessage = instructions.Range("A7").Value
                    GoTo ReviewNeeded
                End If
                If source.Name <> payments.Name And Not HasMonth(source.Cells(row, dateColumn).Value) Then
                    warningMessage = instructions.Range("A5").Value
                    GoTo ReviewNeeded
                End If
                If Not locale Is Nothing Then
                    If source.Name = transactions.Name Then
                        If Not ValidLabel(source.Cells(row, 6).Value2, locale, 14, 16, True) Or Not ValidLabel(source.Cells(row, 7).Value2, locale, 10, 12, True) Then GoTo InvalidLabel
                    ElseIf source.Name = snapshots.Name Then
                        If Not ValidLabel(source.Cells(row, 2).Value2, locale, 17, 18, False) Then GoTo InvalidLabel
                    ElseIf source.Name = debts.Name Then
                        If Not ValidLabel(source.Cells(row, 3).Value2, locale, 19, 20, False) Or Not ValidLabel(source.Cells(row, 8).Value2, locale, 21, 22, False) Then GoTo InvalidLabel
                    End If
                End If
            End If
        Next row
    Next source
    For row = 2 To lastRow
        If IsWorkbookDate(transactions.Cells(row, 3).Value) Then
            If IsEmpty(transactions.Cells(row, 23).Value) Or transactions.Cells(row, 23).Value = "" Then
                links = Trim(CStr(transactions.Cells(row, 22).Value))
                If Len(Trim(CStr(transactions.Cells(row, 1).Value))) > 0 Or (links <> "" And links <> "[]") Then
                    warningMessage = instructions.Range("A6").Value
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
        If locale Is Nothing Then
            transactions.Range("Z2:Z" & lastRow).FormulaR1C1 = "=IF(AND(RC[-19]=""planned"",RC[-18]=TRUE),""pending"",IF(RC[-19]="""",""actual"",RC[-19]))"
        Else
            transactions.Range("Z2:Z" & lastRow).FormulaR1C1 = "=IF(AND(OR(TRIM(RC[-19])=""planned"",TRIM(RC[-19])='_locale'!R11C3),RC[-18]=TRUE),""pending"",IF(OR(TRIM(RC[-19])="""",TRIM(RC[-19])=""actual"",TRIM(RC[-19])='_locale'!R10C3),""actual"",IF(OR(TRIM(RC[-19])=""planned"",TRIM(RC[-19])='_locale'!R11C3),""planned"",IF(OR(TRIM(RC[-19])=""predicted"",TRIM(RC[-19])='_locale'!R12C3),""predicted"",IF(OR(TRIM(RC[-19])=""pending"",TRIM(RC[-19])='_locale'!R13C3),""pending"","""")))))"
        End If
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
                        sheet.Cells(out, 1).Value = transactions.Cells(row, 3).Value
                        sheet.Cells(out, 1).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 2), transactions.Cells(row, 24).Value
                        CopyLiteral sheet.Cells(out, 3), transactions.Cells(row, 4).Value
                        CopyLiteral sheet.Cells(out, 4), transactions.Cells(row, 5).Value
                        CopyLiteral sheet.Cells(out, 5), DisplayStatus(locale, transactions.Cells(row, 26).Value)
                        sheet.Cells(out, 6).Value = transactions.Cells(row, 9).Value
                        CopyLiteral sheet.Cells(out, 7), transactions.Cells(row, 10).Value
                        sheet.Cells(out, 8).Value = transactions.Cells(row, 25).Value
                        sheet.Cells(out, 9).Value = transactions.Cells(row, 23).Value
                        CopyLiteral sheet.Cells(out, 10), DisplayLabel(locale, transactions.Cells(row, 6).Value, 14, 16)
                        out = out + 1
                    End If
                End If
            Next row
            If out = 15 Then
                CopyLiteral sheet.Cells(15, 1), instructions.Range("A8").Value
                out = 16
            End If
            ' The footer follows the last transaction, leaving a blank row.
            out = out + 1
            If Not locale Is Nothing Then
                CopyLiteral sheet.Cells(out, 1), instructions.Range("A12").Value
                sheet.Cells(out, 6).Formula = "=IF($B$2=1,B9,"""")"
                CopyLiteral sheet.Cells(out + 1, 1), instructions.Range("A13").Value
                sheet.Cells(out + 1, 6).Formula = "=IF($B$2=1,C9,"""")"
                CopyLiteral sheet.Cells(out + 2, 1), instructions.Range("A14").Value
                sheet.Cells(out + 2, 6).Formula = "=IF($B$2=1,E9,"""")"
            End If
            out = 15
            For row = 2 To snapshots.Cells(snapshots.Rows.Count, "A").End(xlUp).Row
                If IsWorkbookDate(snapshots.Cells(row, 5).Value) Then
                    If Format(snapshots.Cells(row, 5).Value, "yyyy-mm") = targetMonth Then
                        sheet.Cells(out, 11).Value = snapshots.Cells(row, 5).Value
                        sheet.Cells(out, 11).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 12), DisplayLabel(locale, snapshots.Cells(row, 2).Value, 17, 18)
                        CopyLiteral sheet.Cells(out, 13), snapshots.Cells(row, 12).Value
                        CopyLiteral sheet.Cells(out, 14), snapshots.Cells(row, 4).Value
                        sheet.Cells(out, 15).Value = snapshots.Cells(row, 6).Value
                        sheet.Cells(out, 16).Value = snapshots.Cells(row, 7).Value
                        sheet.Cells(out, 17).Value = snapshots.Cells(row, 8).Value
                        sheet.Cells(out, 18).Value = snapshots.Cells(row, 9).Value
                        If IsNumeric(snapshots.Cells(row, 10).Value) And Not IsEmpty(snapshots.Cells(row, 10).Value) Then
                            sheet.Cells(out, 19).Value = snapshots.Cells(row, 10).Value
                        ElseIf IsNumeric(snapshots.Cells(row, 6).Value) And Not IsEmpty(snapshots.Cells(row, 6).Value) And IsNumeric(snapshots.Cells(row, 8).Value) And Not IsEmpty(snapshots.Cells(row, 8).Value) Then
                            sheet.Cells(out, 19).Value = snapshots.Cells(row, 6).Value - snapshots.Cells(row, 8).Value
                        End If
                        CopyLiteral sheet.Cells(out, 20), snapshots.Cells(row, 11).Value
                        out = out + 1
                    End If
                End If
            Next row
            If out = 15 Then CopyLiteral sheet.Cells(15, 11), instructions.Range("A9").Value
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
                        CopyLiteral sheet.Cells(out, 21), debts.Cells(row, 2).Value
                        CopyLiteral sheet.Cells(out, 22), DisplayLabel(locale, debts.Cells(row, 3).Value, 19, 20)
                        sheet.Cells(out, 23).Value = debts.Cells(row, 4).Value
                        sheet.Cells(out, 24).Value = paymentTotal
                        If IsNumeric(debts.Cells(row, 5).Value) And Not IsEmpty(debts.Cells(row, 5).Value) Then
                            sheet.Cells(out, 25).Value = debts.Cells(row, 5).Value
                        ElseIf IsNumeric(debts.Cells(row, 4).Value) And Not IsEmpty(debts.Cells(row, 4).Value) Then
                            sheet.Cells(out, 25).Value = debts.Cells(row, 4).Value - paymentTotal
                        End If
                        sheet.Cells(out, 26).Value = debts.Cells(row, 6).Value
                        sheet.Cells(out, 27).Value = debts.Cells(row, 7).Value
                        sheet.Cells(out, 26).NumberFormat = "yyyy-mm-dd"
                        sheet.Cells(out, 27).NumberFormat = "yyyy-mm-dd"
                        CopyLiteral sheet.Cells(out, 28), DisplayLabel(locale, debts.Cells(row, 8).Value, 21, 22)
                        CopyLiteral sheet.Cells(out, 29), debts.Cells(row, 10).Value
                        out = out + 1
                    End If
                End If
            Next row
            If out = 15 Then CopyLiteral sheet.Cells(15, 21), instructions.Range("A10").Value
            sheet.Range("B2").Value = 1
            sheet.Range("A3").Value = sheet.Range("A4").Value
        End If
    Next sheet
    Application.CalculateFull
    Application.ScreenUpdating = previousScreenUpdating
    Exit Sub
InvalidLabel:
    warningMessage = instructions.Range("A11").Value
ReviewNeeded:
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then sheet.Range("A3").Value = warningMessage
    Next sheet
    Application.ScreenUpdating = previousScreenUpdating
    Exit Sub
Failed:
    HandleRefreshFailure previousScreenUpdating
End Sub

' A separate procedure has its own error handler. Once RefreshSummaries enters
' its handler, another error in that same procedure cannot be handled there.
Private Sub HandleRefreshFailure(ByVal previousScreenUpdating As Boolean)
    Dim sheet As Worksheet, failureMessage As String, failureValue As Variant
    failureMessage = "Refresh failed; check workbook data."
    ' The instructions and monthly sheets are editable, so cleanup itself must
    ' remain best-effort even if a sheet is missing, invalid, or protected.
    On Error Resume Next
    Err.Clear
    Dim locale As Worksheet, instructions As Worksheet
    Set locale = ThisWorkbook.Worksheets("_locale")
    Err.Clear
    Set instructions = LocalizedSheet(locale, 6, "_instructions")
    failureValue = instructions.Range("A4").Value
    If Err.Number = 0 Then
        If Not IsError(failureValue) And Not IsEmpty(failureValue) Then
            If Len(Trim$(CStr(failureValue))) > 0 Then failureMessage = CStr(failureValue)
        End If
    End If
    Err.Clear
    For Each sheet In ThisWorkbook.Worksheets
        If sheet.Name Like "####-##" Then
            sheet.Range("B2").Value = 0
            sheet.Range("A3").Value = failureMessage
        End If
    Next sheet
    Application.ScreenUpdating = previousScreenUpdating
    On Error GoTo 0
    MsgBox failureMessage, vbExclamation
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
