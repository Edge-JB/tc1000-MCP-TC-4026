# Adversarial offline unit tests for the plc_pou surgical-edit engine.
# Loads the PURE helper region of te1000-bridge.ps1 (no XAE/COM) and replays
# the EXACT mutator logic used inside Invoke-PlcTextRMW for each surgical verb,
# then asserts byte-for-byte preservation of the unchanged surrounding text and
# safe failure on non-unique / zero-match / out-of-bounds anchors.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'te1000-bridge.ps1'
$all = Get-Content -LiteralPath $bridge
$cut = ($all | Select-String -Pattern '^\$payload = Get-Payload' | Select-Object -First 1).LineNumber
if (-not $cut) { throw 'could not find dispatch boundary' }
$region = $all[10..($cut - 2)]
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ce-adv-{0}.ps1" -f ([guid]::NewGuid()))
Set-Content -LiteralPath $tmp -Value $region -Encoding UTF8
. $tmp

$fail = 0; $pass = 0
function Check($name, $cond) {
    if ($cond) { $script:pass++; Write-Host "PASS  $name" }
    else { $script:fail++; Write-Host "FAIL  $name" }
}

# --- Faithful re-implementations of the four splice mutators ----------------
# These mirror the scriptblocks in te1000-bridge.ps1 exactly (line-for-line)
# so a byte-for-byte test exercises the real splice math + Join trailing-EOL.

function Sim-ReplaceLines($text, $startReq, $endReq, $newText) {
    $eol = (Get-TextEol -Text $text).eol
    $lines = @((Split-PlcLines -Text $text).lines)
    $count = $lines.Count
    if ($startReq -lt 1 -or $endReq -gt $count -or $startReq -gt $endReq) {
        throw "replace_lines range [$startReq..$endReq] is out of bounds for lineCount $count (no change written)"
    }
    $repLines = @((Split-PlcLines -Text $newText).lines)
    $before = if ($startReq -gt 1) { @($lines[0..($startReq - 2)]) } else { @() }
    $after = if ($endReq -lt $count) { @($lines[$endReq..($count - 1)]) } else { @() }
    $merged = @($before) + @($repLines) + @($after)
    return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
}

function Sim-Insert($text, $pos, $insText) {
    $eol = (Get-TextEol -Text $text).eol
    $lines = @((Split-PlcLines -Text $text).lines)
    $count = $lines.Count
    if ($pos -lt 1 -or $pos -gt ($count + 1)) {
        throw "insert position $pos is out of bounds for lineCount $count (valid 1..$($count + 1)) (no change written)"
    }
    $insLines = @((Split-PlcLines -Text $insText).lines)
    $before = if ($pos -gt 1) { @($lines[0..($pos - 2)]) } else { @() }
    $after = if ($pos -le $count) { @($lines[($pos - 1)..($count - 1)]) } else { @() }
    $merged = @($before) + @($insLines) + @($after)
    return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
}

function Sim-InsertVarBlock($text, $block, $insText, $occurrence) {
    $eol = (Get-TextEol -Text $text).eol
    $lines = @((Split-PlcLines -Text $text).lines)
    $count = $lines.Count
    $vb = Find-VarBlock -Lines $lines -BlockKeyword $block -Occurrence $occurrence
    if (-not $vb.found) { throw "no $block block found (occurrence $occurrence)" }
    $endVarLine = [int]$vb.endVarLine
    $indent = [string]$vb.indent + '    '
    $insLines = @((Split-PlcLines -Text $insText).lines | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { $_ } else { $indent + $_.TrimStart() }
    })
    $insertPos = $endVarLine
    $before = if ($insertPos -gt 1) { @($lines[0..($insertPos - 2)]) } else { @() }
    $after = @($lines[($insertPos - 1)..($count - 1)])
    $merged = @($before) + @($insLines) + @($after)
    return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $true
}

function Sim-Append($text, $appText) {
    $eol = (Get-TextEol -Text $text).eol
    $lines = @((Split-PlcLines -Text $text).lines)
    $oldCount = $lines.Count
    $appSplit = Split-PlcLines -Text $appText
    $appLines = @($appSplit.lines)
    if ($oldCount -eq 0) {
        return Join-PlcLines -Lines $appLines -Eol $eol -TrailingEol $appSplit.trailingEol
    }
    $merged = @($lines) + @($appLines)
    return Join-PlcLines -Lines $merged -Eol $eol -TrailingEol $appSplit.trailingEol
}

# Apply-Replace is the pure verb itself; replace mutator just runs it.

# ===========================================================================
# 1. MULTI-LINE replace via Apply-Replace (literal, spans CRLF)
# ===========================================================================
$txt = "PROGRAM p`r`nVAR`r`n    a : INT;`r`n    b : INT;`r`nEND_VAR"
$ml = Apply-Replace -Text $txt -Find "    a : INT;`r`n    b : INT;" -ReplaceWith "    a : DINT;`r`n    b : DINT;" -ExpectCount 1
Check 'multiline replace ok' ($ml.ok -and $ml.count -eq 1)
Check 'multiline replace preserves head/tail byte-for-byte' (
    $ml.newText -eq "PROGRAM p`r`nVAR`r`n    a : DINT;`r`n    b : DINT;`r`nEND_VAR")

# ===========================================================================
# 2. ANCHOR appearing inside a comment -> non-unique => FAIL safely
# ===========================================================================
$cmt = "VAR`r`n    x : INT; // set x := 1`r`n    x := 1;`r`nEND_VAR"
$arc = Apply-Replace -Text $cmt -Find 'x := 1' -ReplaceWith 'x := 2' -ExpectCount 1
Check 'anchor in comment makes it non-unique => not ok' (-not $arc.ok -and $arc.count -eq 2)
Check 'anchor in comment: NO change written' ($arc.newText -eq $cmt)
# Disambiguate by including the statement terminator+newline (unique).
$arc2 = Apply-Replace -Text $cmt -Find "    x := 1;" -ReplaceWith "    x := 2;" -ExpectCount 1
Check 'disambiguated anchor ok, comment line untouched' (
    $arc2.ok -and $arc2.newText -eq "VAR`r`n    x : INT; // set x := 1`r`n    x := 2;`r`nEND_VAR")

# ===========================================================================
# 3. INSERT at line 1 and at lineCount+1; OOB fails
# ===========================================================================
$base = "L1`r`nL2`r`nL3"   # 3 lines, no trailing eol
$i1 = Sim-Insert $base 1 "NEW"
Check 'insert at 1 prepends, rest preserved' ($i1 -eq "NEW`r`nL1`r`nL2`r`nL3`r`n")
$iEnd = Sim-Insert $base 4 "NEW"   # lineCount+1
Check 'insert at lineCount+1 appends' ($iEnd -eq "L1`r`nL2`r`nL3`r`nNEW`r`n")
$oob = $false
try { Sim-Insert $base 5 "X" } catch { $oob = $true }
Check 'insert at lineCount+2 throws OOB' ($oob)
$oob0 = $false
try { Sim-Insert $base 0 "X" } catch { $oob0 = $true }
Check 'insert at 0 throws OOB' ($oob0)

# ===========================================================================
# 4. REPLACE_LINES covering the WHOLE text
# ===========================================================================
$whole = Sim-ReplaceLines $base 1 3 "ONLY"
Check 'replace_lines 1..lineCount replaces all' ($whole -eq "ONLY`r`n")
$wholeMulti = Sim-ReplaceLines $base 1 3 "A`r`nB"
Check 'replace_lines whole with multi-line text' ($wholeMulti -eq "A`r`nB`r`n")
# OOB beyond end
$rlo = $false
try { Sim-ReplaceLines $base 2 9 "X" } catch { $rlo = $true }
Check 'replace_lines end>lineCount throws' ($rlo)
# start>end
$rls = $false
try { Sim-ReplaceLines $base 3 2 "X" } catch { $rls = $true }
Check 'replace_lines start>end throws' ($rls)
# middle replacement preserves head + tail exactly
$mid = Sim-ReplaceLines $base 2 2 "MID"
Check 'replace_lines middle preserves L1 and L3' ($mid -eq "L1`r`nMID`r`nL3`r`n")

# ===========================================================================
# 5. INSERT_IN_VAR_BLOCK: multiple blocks, none, empty block
# ===========================================================================
$multi = "TYPE x`r`nVAR`r`n    a : INT;`r`nEND_VAR`r`nVAR`r`n    b : INT;`r`nEND_VAR"
$v1 = Sim-InsertVarBlock $multi 'VAR' "n : BOOL;" 1
Check 'insert_in_var_block occ1 before first END_VAR' (
    $v1 -eq "TYPE x`r`nVAR`r`n    a : INT;`r`n    n : BOOL;`r`nEND_VAR`r`nVAR`r`n    b : INT;`r`nEND_VAR`r`n")
$v2 = Sim-InsertVarBlock $multi 'VAR' "n : BOOL;" 2
Check 'insert_in_var_block occ2 before second END_VAR' (
    $v2 -eq "TYPE x`r`nVAR`r`n    a : INT;`r`nEND_VAR`r`nVAR`r`n    b : INT;`r`n    n : BOOL;`r`nEND_VAR`r`n")
$vNone = $false
try { Sim-InsertVarBlock $multi 'VAR_INPUT' "n : BOOL;" 1 } catch { $vNone = $true }
Check 'insert_in_var_block: no such block throws' ($vNone)
$vOcc = $false
try { Sim-InsertVarBlock $multi 'VAR' "n : BOOL;" 3 } catch { $vOcc = $true }
Check 'insert_in_var_block: occurrence out of range throws' ($vOcc)
# empty VAR block
$emptyB = "FUNCTION_BLOCK fb`r`nVAR_INPUT`r`nEND_VAR"
$vE = Sim-InsertVarBlock $emptyB 'VAR_INPUT' "i : INT;" 1
Check 'insert into empty VAR_INPUT' ($vE -eq "FUNCTION_BLOCK fb`r`nVAR_INPUT`r`n    i : INT;`r`nEND_VAR`r`n")

# ===========================================================================
# 6. CRLF vs LF preservation through each mutator
# ===========================================================================
$lfTxt = "L1`nL2`nL3"
$lfIns = Sim-Insert $lfTxt 2 "MID"
Check 'LF insert keeps LF only (no CR)' ($lfIns -eq "L1`nMID`nL2`nL3`n" -and ($lfIns.IndexOf("`r") -lt 0))
$lfRep = Sim-ReplaceLines $lfTxt 1 1 "X"
Check 'LF replace_lines keeps LF only' ($lfRep -eq "X`nL2`nL3`n" -and ($lfRep.IndexOf("`r") -lt 0))
$crlfIns = Sim-Insert $base 2 "MID"
Check 'CRLF insert keeps CRLF' ($crlfIns -eq "L1`r`nMID`r`nL2`r`nL3`r`n")
# append preserves source EOL and respects appText trailing-eol
$apLf = Sim-Append $lfTxt "X"
Check 'LF append no CR' ($apLf -eq "L1`nL2`nL3`nX" -and ($apLf.IndexOf("`r") -lt 0))

# ===========================================================================
# 7. EMPTY implementation: append seeds it
# ===========================================================================
$apEmpty = Sim-Append '' "first := TRUE;"
Check 'append to empty impl seeds text' ($apEmpty -eq 'first := TRUE;')
$apEmptyEol = Sim-Append '' "a`r`nb`r`n"
Check 'append to empty impl keeps appText trailing eol' ($apEmptyEol -eq "a`r`nb`r`n")
# insert into empty text: only pos 1 is valid (lineCount 0 => 1..1)
$insEmpty = Sim-Insert '' 1 "x"
Check 'insert at 1 into empty text' ($insEmpty -eq "x`r`n")
$insEmptyOob = $false
try { Sim-Insert '' 2 "x" } catch { $insEmptyOob = $true }
Check 'insert at 2 into empty text throws' ($insEmptyOob)

# ===========================================================================
# 8. GREP / Find-MatchesInText with regex special chars (literal-ish)
# ===========================================================================
$rx = "a := arr[1];`r`nb := f(x);`r`nc := a.b;"
# Bracket is a regex metachar; an unescaped pattern '[1]' = char-class '1'.
$m1 = @(Find-MatchesInText -Text $rx -Pattern '\[1\]' -Section 'impl' -Path 'X' -IgnoreCase $false)
Check 'grep escaped [1] matches line 1' ($m1.Count -eq 1 -and $m1[0].line -eq 1)
$m2 = @(Find-MatchesInText -Text $rx -Pattern '\(x\)' -Section 'impl' -Path 'X' -IgnoreCase $false)
Check 'grep escaped (x) matches line 2' ($m2.Count -eq 1 -and $m2[0].line -eq 2)
$m3 = @(Find-MatchesInText -Text $rx -Pattern 'a\.b' -Section 'impl' -Path 'X' -IgnoreCase $false)
Check 'grep escaped a.b matches line 3' ($m3.Count -eq 1 -and $m3[0].line -eq 3)
# Apply-Replace must treat metachars LITERALLY (it is not regex).
$litRep = Apply-Replace -Text $rx -Find 'arr[1]' -ReplaceWith 'arr[2]' -ExpectCount 1
Check 'replace treats [1] literally' ($litRep.ok -and $litRep.newText.Contains('arr[2]'))

# ===========================================================================
# 9. Divergence snippet bounds correctness on a real replace
# ===========================================================================
$dtxt = "a`r`nb`r`nc`r`nd"
$dr = Apply-Replace -Text $dtxt -Find 'b' -ReplaceWith 'B' -ExpectCount 1
$oldL = @((Split-PlcLines -Text $dtxt).lines)
$newL = @((Split-PlcLines -Text $dr.newText).lines)
$fd = Get-FirstDivergentLine -OldLines $oldL -NewLines $newL
$ld = Get-LastDivergentLine -OldLines $oldL -NewLines $newL
Check 'divergence first/last both line 2' ($fd -eq 2 -and $ld -eq 2)

# ===========================================================================
# 10. Whole-text byte preservation: only patched region changes (insert mid)
# ===========================================================================
$big = (1..20 | ForEach-Object { "line$_" }) -join "`r`n"
$bigIns = Sim-Insert $big 10 "INSERTED"
$bigLines = @((Split-PlcLines -Text $bigIns).lines)
Check 'big insert: line count 21' ($bigLines.Count -eq 21)
Check 'big insert: inserted at idx 10 (line 10)' ($bigLines[9] -eq 'INSERTED')
Check 'big insert: line 9 preserved' ($bigLines[8] -eq 'line9')
Check 'big insert: line 10 shifted to 11' ($bigLines[10] -eq 'line10')
Check 'big insert: tail line20 preserved' ($bigLines[20] -eq 'line20')

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
