# Offline unit tests for the plc_pou code_engine PURE helpers.
# Extracts the function-definition region of te1000-bridge.ps1 (everything
# before the dispatch's `$payload = Get-Payload`) into a temp module so the
# pure string helpers can be exercised with NO XAE/COM attach.
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'te1000-bridge.ps1'
$all = Get-Content -LiteralPath $bridge
# region = lines after the param block, up to the line before '$payload = Get-Payload'
$cut = ($all | Select-String -Pattern '^\$payload = Get-Payload' | Select-Object -First 1).LineNumber
if (-not $cut) { throw 'could not find dispatch boundary' }
$region = $all[10..($cut - 2)]  # skip param() (lines 1-7) + prefs; keep funcs
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ce-funcs-{0}.ps1" -f ([guid]::NewGuid()))
Set-Content -LiteralPath $tmp -Value $region -Encoding UTF8
. $tmp

$fail = 0
$pass = 0
function Check($name, $cond) {
    if ($cond) { $script:pass++; Write-Host "PASS  $name" }
    else { $script:fail++; Write-Host "FAIL  $name" }
}

# --- fixtures --------------------------------------------------------------
$crlf = "FUNCTION_BLOCK fb_Test EXTENDS fb_Base IMPLEMENTS I_A, I_B`r`nVAR_INPUT`r`n    iIn : BOOL;`r`nEND_VAR`r`nVAR`r`n    iLocal : INT;`r`nEND_VAR"
$lf   = "PROGRAM pMain`nVAR`n    a : INT;`n    b : INT;`nEND_VAR"
$emptyVar = "FUNCTION_BLOCK fb_E`r`nVAR_INPUT`r`nEND_VAR"
$commented = "FUNCTION_BLOCK fb_C`r`nVAR`r`n    // END_VAR is not really here`r`n    (* END_VAR *)`r`n    x : INT;`r`nEND_VAR"
$multiVar = "TYPE notused`r`nVAR`r`n    a : INT;`r`nEND_VAR`r`nVAR`r`n    b : INT;`r`nEND_VAR"

# --- Get-TextEol -----------------------------------------------------------
Check 'eol CRLF' ((Get-TextEol -Text $crlf).name -eq 'CRLF')
Check 'eol LF'   ((Get-TextEol -Text $lf).name -eq 'LF')
Check 'eol empty defaults CRLF' ((Get-TextEol -Text '').name -eq 'CRLF')

# --- Split-PlcLines --------------------------------------------------------
$sc = Split-PlcLines -Text $crlf
Check 'split CRLF count 7' (@($sc.lines).Count -eq 7)
Check 'split CRLF no trailing eol' ($sc.trailingEol -eq $false)
$sl = Split-PlcLines -Text $lf
Check 'split LF count 5' (@($sl.lines).Count -eq 5)
$se = Split-PlcLines -Text ''
Check 'split empty => 0' (@($se.lines).Count -eq 0)
$st = Split-PlcLines -Text "a`r`nb`r`n"
Check 'split trailing eol flagged' ($st.trailingEol -eq $true -and @($st.lines).Count -eq 2)

# --- Join-PlcLines round-trip ---------------------------------------------
$rtCrlf = Join-PlcLines -Lines $sc.lines -Eol "`r`n" -TrailingEol $sc.trailingEol
Check 'roundtrip CRLF identity' ($rtCrlf -eq $crlf)
$rtLf = Join-PlcLines -Lines $sl.lines -Eol "`n" -TrailingEol $sl.trailingEol
Check 'roundtrip LF identity' ($rtLf -eq $lf)

# --- Get-LineSlice (range) -------------------------------------------------
$slice = Get-LineSlice -Lines $sl.lines -Start 2 -End 3
Check 'slice 2..3 count 2' (@($slice.slice).Count -eq 2 -and $slice.slice[0] -eq 'VAR')
Check 'slice in-bounds not oob' ($slice.outOfBounds -eq $false)
$slOob = Get-LineSlice -Lines $sl.lines -Start 3 -End 99
Check 'slice OOB clamps to lineCount' ($slOob.clampedEnd -eq 5 -and $slOob.outOfBounds -eq $true)

# --- Select-GrepLines ------------------------------------------------------
$g = Select-GrepLines -Lines $sl.lines -Pattern 'INT' -Context 0
Check 'grep INT matches 2 (a,b)' (@($g).Count -eq 2)
$gc = Select-GrepLines -Lines $sl.lines -Pattern '\ba\b' -Context 1
Check 'grep with context merges' (@($gc).Count -ge 2)
$gn = Select-GrepLines -Lines $sl.lines -Pattern 'ZZZ_no_match' -Context 2
Check 'grep no-match => empty (not error)' (@($gn).Count -eq 0)
$badRegex = $false
try { Select-GrepLines -Lines $sl.lines -Pattern '[' -Context 1 } catch { $badRegex = $true }
Check 'grep invalid regex throws' ($badRegex)

# --- Find-VarBlock ---------------------------------------------------------
$vbIn = Find-VarBlock -Lines $sc.lines -BlockKeyword 'VAR_INPUT' -Occurrence 1
Check 'find VAR_INPUT start=2 endvar=4' ($vbIn.found -and $vbIn.startLine -eq 2 -and $vbIn.endVarLine -eq 4)
$vbVar = Find-VarBlock -Lines $sc.lines -BlockKeyword 'VAR' -Occurrence 1
Check 'find VAR (not VAR_INPUT) start=5' ($vbVar.found -and $vbVar.startLine -eq 5 -and $vbVar.endVarLine -eq 7)
$vbMissing = Find-VarBlock -Lines $sc.lines -BlockKeyword 'VAR_OUTPUT' -Occurrence 1
Check 'find missing block => not found' (-not $vbMissing.found)
$evb = Split-PlcLines -Text $emptyVar
$vbEmpty = Find-VarBlock -Lines $evb.lines -BlockKeyword 'VAR_INPUT' -Occurrence 1
Check 'find empty VAR_INPUT endvar=3' ($vbEmpty.found -and $vbEmpty.endVarLine -eq 3)
$cvb = Split-PlcLines -Text $commented
$vbCom = Find-VarBlock -Lines $cvb.lines -BlockKeyword 'VAR' -Occurrence 1
Check 'find ignores commented END_VAR (endvar=6)' ($vbCom.found -and $vbCom.endVarLine -eq 6)
$mvb = Split-PlcLines -Text $multiVar
$vb2 = Find-VarBlock -Lines $mvb.lines -BlockKeyword 'VAR' -Occurrence 2
Check 'find 2nd VAR occurrence start=5' ($vb2.found -and $vb2.startLine -eq 5)
$vb3 = Find-VarBlock -Lines $mvb.lines -BlockKeyword 'VAR' -Occurrence 3
Check 'find occurrence out of range => not found' (-not $vb3.found)

# --- Get-DeclOutline -------------------------------------------------------
$ol = Get-DeclOutline -Lines $sc.lines
Check 'outline header keyword FUNCTION_BLOCK' ($ol.header.keyword -eq 'FUNCTION_BLOCK')
Check 'outline header name fb_Test' ($ol.header.name -eq 'fb_Test')
Check 'outline header extends fb_Base' ($ol.header.extends -eq 'fb_Base')
Check 'outline header implements I_A, I_B' ($ol.header.implements -eq 'I_A, I_B')
Check 'outline 2 var blocks' (@($ol.varBlocks).Count -eq 2)
Check 'outline VAR_INPUT varCount 1' (($ol.varBlocks | Where-Object { $_.kind -eq 'VAR_INPUT' }).varCount -eq 1)

# --- Apply-Replace ---------------------------------------------------------
$ar1 = Apply-Replace -Text 'a := 1; a := 1;' -Find 'a := 1;' -ReplaceWith 'b := 2;' -ExpectCount 2
Check 'replace expectCount 2 ok' ($ar1.ok -and $ar1.count -eq 2 -and $ar1.newText -eq 'b := 2; b := 2;')
$ar0 = Apply-Replace -Text 'hello' -Find 'xyz' -ReplaceWith 'q' -ExpectCount 1
Check 'replace count 0 => not ok, no change' (-not $ar0.ok -and $ar0.newText -eq 'hello')
$arN = Apply-Replace -Text 'a a a' -Find 'a' -ReplaceWith 'b' -ExpectCount 1
Check 'replace non-unique default => not ok' (-not $arN.ok -and $arN.count -eq 3)

# --- Get-ChangedSnippet ----------------------------------------------------
$snip = Get-ChangedSnippet -NewLines $sl.lines -Start 3 -End 3 -Context 1
Check 'snippet changedRange 3..3' ($snip.changedRange.start -eq 3 -and $snip.changedRange.end -eq 3)
Check 'snippet has context lines (2,3,4)' (@($snip.snippet).Count -eq 3)

# --- divergence helpers (back replace snippet) -----------------------------
$old = @('a','b','c','d')
$new = @('a','X','Y','d')
Check 'first divergent line 2' ((Get-FirstDivergentLine -OldLines $old -NewLines $new) -eq 2)
Check 'last divergent line 3' ((Get-LastDivergentLine -OldLines $old -NewLines $new) -eq 3)
Check 'identical => null first' ($null -eq (Get-FirstDivergentLine -OldLines $old -NewLines $old))

# --- graphical language gate -----------------------------------------------
Check 'lang 1 (ST) not graphical' (-not (Test-PlcGraphicalLanguage -Language 1))
Check 'lang 2 (IL) not graphical' (-not (Test-PlcGraphicalLanguage -Language 2))
Check 'lang 3 (SFC) graphical' (Test-PlcGraphicalLanguage -Language 3)
Check 'lang 5 (CFC) graphical' (Test-PlcGraphicalLanguage -Language 5)
Check 'lang name SFC' ((Get-PlcLanguageName -Language 3) -eq 'SFC')

# --- splice math (mirrors the RMW mutators) --------------------------------
# replace_lines: replace lines 3..3 of $lf ("    a : INT;") with two lines
$lines = @($sl.lines)
$rep = @('    x : DINT;', '    y : DINT;')
$before = @($lines[0..1]); $after = @($lines[3..4])
$merged = @($before) + @($rep) + @($after)
Check 'replace_lines splice count 6' (@($merged).Count -eq 6)
Check 'replace_lines new line at 3' ($merged[2] -eq '    x : DINT;')

# insert before line 2 (at=2)
$ins = @('// header comment')
$pos = 2
$b = @($lines[0..($pos-2)]); $a = @($lines[($pos-1)..($lines.Count-1)])
$m2 = @($b) + @($ins) + @($a)
Check 'insert at 2 places comment at idx2' ($m2[1] -eq '// header comment' -and @($m2).Count -eq 6)

# insert at end (at = lineCount+1)
$posEnd = $lines.Count + 1
$bE = @($lines[0..($posEnd-2)]); $aE = @()
$mEnd = @($bE) + @($ins) + @($aE)
Check 'insert at end appends' ($mEnd[$mEnd.Count-1] -eq '// header comment' -and @($mEnd).Count -eq 6)

# insert_in_var_block: insert before END_VAR of $emptyVar's VAR_INPUT (line 3)
$evLines = @($evb.lines)
$endVar = $vbEmpty.endVarLine  # 3
$bV = @($evLines[0..($endVar-2)]); $aV = @($evLines[($endVar-1)..($evLines.Count-1)])
$mV = @($bV) + @('    iNew : BOOL;') + @($aV)
Check 'insert_in_var_block before END_VAR' ($mV[2] -eq '    iNew : BOOL;' -and $mV[3] -eq 'END_VAR')

# append to a non-eol-terminated text adds a separating line
$appMerged = @($lines) + @('// appended')
Check 'append adds line at end' ($appMerged[$appMerged.Count-1] -eq '// appended')

# --- Find-MatchesInText (project-wide search grep core) --------------------
# (wrap each result in @() before indexing: PS unwraps single-element arrays)
# CRLF text: 1-based line numbers, trimmed match text.
$mCrlf = @(Find-MatchesInText -Text $crlf -Pattern 'iIn' -Section 'decl' -Path 'P^fb_Test' -IgnoreCase $false)
Check 'find CRLF iIn one hit line 3' ($mCrlf.Count -eq 1 -and $mCrlf[0].line -eq 3 -and $mCrlf[0].text -eq 'iIn : BOOL;')
Check 'find CRLF section + path carried' ($mCrlf[0].section -eq 'decl' -and $mCrlf[0].path -eq 'P^fb_Test')
# LF text.
$mLf = @(Find-MatchesInText -Text $lf -Pattern 'INT' -Section 'impl' -Path 'P^pMain' -IgnoreCase $false)
Check 'find LF INT two hits lines 3,4' ($mLf.Count -eq 2 -and $mLf[0].line -eq 3 -and $mLf[1].line -eq 4)
# Lone CR (old-Mac) line endings.
$crText = "AAA`rbbb VAR`rccc"
$mCr = @(Find-MatchesInText -Text $crText -Pattern 'VAR' -Section 'decl' -Path 'X' -IgnoreCase $false)
Check 'find lone-CR VAR hit at line 2' ($mCr.Count -eq 1 -and $mCr[0].line -eq 2 -and $mCr[0].text -eq 'bbb VAR')
# ignoreCase: case-sensitive misses, ignoreCase hits.
$mCs = @(Find-MatchesInText -Text $lf -Pattern 'program' -Section 'decl' -Path 'X' -IgnoreCase $false)
Check 'find case-sensitive misses lower program' ($mCs.Count -eq 0)
$mCi = @(Find-MatchesInText -Text $lf -Pattern 'program' -Section 'decl' -Path 'X' -IgnoreCase $true)
Check 'find ignoreCase hits PROGRAM line 1' ($mCi.Count -eq 1 -and $mCi[0].line -eq 1)
# No-match => empty array, not error.
$mNo = @(Find-MatchesInText -Text $crlf -Pattern 'ZZZ_no_such_token' -Section 'decl' -Path 'X' -IgnoreCase $false)
Check 'find no-match => empty (not error)' ($mNo.Count -eq 0)
# Empty / whitespace text => 0 matches.
$mEmpty = @(Find-MatchesInText -Text '' -Pattern 'x' -Section 'decl' -Path 'X' -IgnoreCase $false)
Check 'find empty text => 0' ($mEmpty.Count -eq 0)
# Invalid regex => clear throw.
$badPat = $false
try { Find-MatchesInText -Text $lf -Pattern '[' -Section 'decl' -Path 'X' -IgnoreCase $false } catch { $badPat = ($_.Exception.Message -like 'invalid pattern:*') }
Check 'find invalid regex throws invalid pattern' ($badPat)
# Regex anchors compose with per-line splitting.
$mAnchor = @(Find-MatchesInText -Text $lf -Pattern '^VAR$' -Section 'decl' -Path 'X' -IgnoreCase $false)
Check 'find anchored ^VAR$ hits line 2 only' ($mAnchor.Count -eq 1 -and $mAnchor[0].line -eq 2)

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
