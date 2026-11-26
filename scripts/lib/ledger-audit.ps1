<#
.SYNOPSIS
    文档台账一致性审计（合并前自检与 CI 共用）。
.DESCRIPTION
    检查项：
      1. docs\01-文档台账.md 每一行 <-> 文档内属性表（文档编号 / 版本 / 最后更新 / 状态），编号唯一、状态取值合法；
      2. 变更记录末行（版本 == 头部版本、日期 == 最后更新），变更记录版本严格升序且不重复；
      3. 磁盘上的 Markdown 均已在台账登记（.github 模板与台账自身除外）；
      4. 语义校验：状态为「生效（A）」的验收记录（DOC-OPS-ACCEPT-*）结论栏不得全空
         （结论栏 = 标题含「结论」的小节下，表头列名以「结果」或「结论」开头的表格）；
      5. scripts 下全部 .ps1 带 UTF-8 BOM（Windows PowerShell 5.1 才能正确识别中文）；
      6. 问题记录（DOC-OPS-ISSUE-001）的 DEV 编号按出现顺序递增、不重复、不跳号
         （已停用的编号以「已关闭」条目留档，不留例外清单）。
    任一项不通过时退出码为 1。本脚本只读，不修改任何文件。
    规则来源：docs\00-文档管理规范.md（第 5、6、7、8 节）。
.PARAMETER RepoRoot
    仓库根目录。直接运行本文件且未指定时，取 scripts\lib 的上两级目录。
.EXAMPLE
    PS> pwsh -NoProfile -File scripts\lib\ledger-audit.ps1
    在仓库根执行；逐项输出 PASS / FAIL 与汇总，失败时退出码为 1。
.EXAMPLE
    PS> . .\scripts\lib\ledger-audit.ps1; Get-McpLedgerAuditResult -RepoRoot (Get-Location).Path
    以库方式调用，返回每一项检查结果（Ok / Message），由调用方决定如何输出。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

# L4 记录类文档只追加条目，没有「## 变更记录」表，跳过变更记录比对
$script:McpLedgerRecordIds = @('DOC-OPS-TASK-001', 'DOC-OPS-ISSUE-001', 'DOC-OPS-CHANGE-001')

function Get-McpLedgerAuditResult {
    # 返回每一项检查结果：[pscustomobject]@{ Ok = $true/$false; Message = 说明 }
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    $results = New-Object System.Collections.Generic.List[object]

    function Add-Result([bool]$Ok, [string]$Message) {
        # 说明文字为空说明格式化表达式出了问题（例如 -f 的参数类型不对），不能当作通过
        if ([string]::IsNullOrWhiteSpace($Message)) {
            $Ok = $false
            $Message = '审计脚本内部错误：有检查项未生成说明文字（请检查 scripts/lib/ledger-audit.ps1 的格式化表达式）'
        }
        $results.Add([pscustomobject]@{ Ok = $Ok; Message = $Message })
    }

    $ledgerPath = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'docs') -ChildPath '01-文档台账.md'
    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        Add-Result $false '台账文件存在：docs/01-文档台账.md'
        return ,$results
    }
    $ledger = [IO.File]::ReadAllText($ledgerPath, [Text.Encoding]::UTF8)
    $sep = [IO.Path]::DirectorySeparatorChar

    # 台账数据行：| 编号 | 名称 | 版本 | 状态 | `路径` | 作者 | 最后更新 | ……
    $rowRe = '^\| (—|(?:DOC|AI)-(?:[A-Z]+-)+\d+) \| ([^|]+) \| (v\d+\.\d+\.\d+|—) \| ([^|]+) \| `?([^|`]+)`? \| ([^|]+) \| (\d{4}-\d{2}-\d{2}) \|'
    $rows = @{}
    $registered = New-Object System.Collections.Generic.List[string]
    $duplicate = New-Object System.Collections.Generic.List[string]
    foreach ($line in [regex]::Split($ledger, '\r?\n')) {
        $m = [regex]::Match($line, $rowRe)
        if (-not $m.Success) { continue }
        $id = $m.Groups[1].Value.Trim()
        if ($rows.ContainsKey($id)) { $duplicate.Add($id) }
        $rows[$id] = @{
            Name    = $m.Groups[2].Value.Trim()
            Version = $m.Groups[3].Value.Trim()
            Status  = $m.Groups[4].Value.Trim()
            Path    = ($m.Groups[5].Value.Trim() -replace '\\', '/')
            Date    = $m.Groups[7].Value.Trim()
        }
        $registered.Add(($m.Groups[5].Value.Trim() -replace '\\', '/'))
    }
    Add-Result ($rows.Count -ge 15) ('台账数据行数 {0}' -f $rows.Count)
    Add-Result ($duplicate.Count -eq 0) ('台账编号唯一（重复：{0}）' -f $(if ($duplicate.Count) { $duplicate -join '、' } else { '无' }))
    $statusRe = '^(草稿（D）|评审中（R）|生效（A）|归档（X）)$'

    foreach ($id in @($rows.Keys | Sort-Object)) {
        $r = $rows[$id]
        if ($id -eq '—' -or $id -eq 'DOC-REG-001') { continue }   # README 等无属性表文档、台账自身以台账为准
        $full = Join-Path -Path $RepoRoot -ChildPath ($r.Path -replace '/', $sep)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Add-Result $false ('{0} 文件存在' -f $id)
            continue
        }
        $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        $docId = [regex]::Match($text, '\| 文档编号 \| ([^|]+) \|').Groups[1].Value.Trim()
        $ver = [regex]::Match($text, '(?m)^\| 版本 \| (v\d+\.\d+\.\d+) \|').Groups[1].Value.Trim()
        $upd = [regex]::Match($text, '(?m)^\| 最后更新 \| (\d{4}-\d{2}-\d{2}) \|').Groups[1].Value.Trim()
        $st = [regex]::Match($text, '(?m)^\| 状态 \| ([^|]+?) \|\r?$').Groups[1].Value.Trim()
        Add-Result ($docId -eq $id) ('{0} 文内编号 {1}' -f $id, $docId)
        Add-Result ($ver -eq $r.Version) ('{0} 版本 台账={1} 文内={2}' -f $id, $r.Version, $ver)
        Add-Result ($upd -eq $r.Date) ('{0} 最后更新 台账={1} 文内={2}' -f $id, $r.Date, $upd)
        Add-Result ($st -eq $r.Status) ('{0} 状态 台账={1} 文内={2}' -f $id, $r.Status, $st)
        Add-Result ($r.Status -match $statusRe) ('{0} 状态取值合法（{1}）' -f $id, $r.Status)

        # 语义校验（验收记录 DOC-OPS-ACCEPT-*，与 docs\00 第 6、8.5 节一致）：
        #   生效（A）→ 结论栏不得全空（结论未回填的验收记录不能作为依据）；
        #   评审中（R）→ 正常，提示结论栏回填进度（回填完成后才可转 A）。
        # 结论栏的识别规则：位于标题含「结论」的小节下，表头列名以「结果」或「结论」开头的表格；
        # 其他表格（如握手探活的「结果 / 输出 / 说明」对照表）不计入。
        if ($id -match '^DOC-OPS-ACCEPT-\d+$' -and $r.Status -ne '归档（X）') {
            $filled = 0
            $tables = 0
            $col = -1
            $inConclusion = $false
            foreach ($line in [regex]::Split($text, '\r?\n')) {
                if ($line -match '^(#{2,4})\s+(.*)$') {
                    $inConclusion = $Matches[2] -match '结论'
                    $col = -1
                    continue
                }
                if (-not $inConclusion) { continue }
                if ($line -notmatch '^\s*\|') { $col = -1; continue }   # 离开表格后重新定位表头
                if ($line -match '^\s*\|\s*-{3,}') { continue }          # 表头分隔行
                $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
                if ($col -lt 0) {
                    for ($i = 0; $i -lt $cells.Count; $i++) {
                        if ($cells[$i] -match '^(结果|结论)') { $col = $i; $tables++; break }
                    }
                    continue
                }
                if ($col -lt $cells.Count -and $cells[$col] -ne '') { $filled++ }
            }
            if ($r.Status -eq '生效（A）') {
                Add-Result ($tables -gt 0 -and $filled -gt 0) ('{0} 语义：状态为生效（A）的验收记录结论栏不得全空（结论栏表格 {1} 个，已填写 {2} 格）' -f $id, $tables, $filled)
            }
            else {
                Add-Result $true ('{0} 语义：评审中（R）的验收记录不作结论要求（结论栏表格 {1} 个，已填写 {2} 格；回填完成后才可转 A）' -f $id, $tables, $filled)
            }
        }

        # 编号连续性校验（问题记录 DOC-OPS-ISSUE-001，与 docs\00 第 8.3 节一致）：
        #   DEV 编号按出现顺序严格递增、不重复、不跳号；已停用的编号以「已关闭」条目留档，不留例外清单。
        if ($id -eq 'DOC-OPS-ISSUE-001') {
            $nums = @([regex]::Matches($text, '(?m)^\| DEV-(\d+) \|') | ForEach-Object { [int]$_.Groups[1].Value })
            $dup = @($nums | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { 'DEV-{0:D3}' -f [int]$_.Name })
            $disorder = New-Object System.Collections.Generic.List[string]
            for ($i = 1; $i -lt $nums.Count; $i++) {
                if ($nums[$i] -le $nums[$i - 1]) { $disorder.Add(('DEV-{0:D3}' -f $nums[$i])) }
            }
            $gaps = New-Object System.Collections.Generic.List[string]
            $lo = 0; $hi = 0
            if ($nums.Count) {
                # Measure-Object 返回 double，而 D3 只接受整数，必须先转 int
                $lo = [int]($nums | Measure-Object -Minimum).Minimum
                $hi = [int]($nums | Measure-Object -Maximum).Maximum
                for ($n = $lo; $n -le $hi; $n++) { if ($nums -notcontains $n) { $gaps.Add(('DEV-{0:D3}' -f $n)) } }
            }
            $none = '无'
            Add-Result ($nums.Count -ge 1) '问题记录 DEV 条目至少 1 行'
            Add-Result ($dup.Count -eq 0) ('问题记录 DEV 编号不重复（重复：{0}）' -f $(if ($dup.Count) { $dup -join '、' } else { $none }))
            Add-Result ($disorder.Count -eq 0) ('问题记录 DEV 编号按出现顺序递增（乱序：{0}）' -f $(if ($disorder.Count) { $disorder -join '、' } else { $none }))
            $gapText = $none
            if ($gaps.Count) { $gapText = ($gaps -join '、') }
            $contOk = ($nums.Count -ge 1 -and $lo -eq 1 -and $gaps.Count -eq 0)
            $contText = '问题记录 DEV 编号连续、不跳号（共 {0} 条，DEV-{1:D3}～DEV-{2:D3}；缺号：{3}）' -f @($nums.Count, $lo, $hi, $gapText)
            Add-Result $contOk $contText
        }

        if ($script:McpLedgerRecordIds -contains $id) { continue }
        $idx = $text.IndexOf('## 变更记录', [StringComparison]::Ordinal)
        if ($idx -lt 0) {
            Add-Result $false ('{0} 含变更记录' -f $id)
            continue
        }
        $recs = @([regex]::Matches($text.Substring($idx), '(?m)^\| (v\d+\.\d+\.\d+) \| (\d{4}-\d{2}-\d{2}) \|'))
        Add-Result ($recs.Count -ge 1) ('{0} 变更记录至少 1 行' -f $id)
        if ($recs.Count) {
            $last = $recs[$recs.Count - 1]
            Add-Result ($last.Groups[1].Value.Trim() -eq $ver) ('{0} 变更记录末行版本 {1} == 头部' -f $id, $last.Groups[1].Value.Trim())
            Add-Result ($last.Groups[2].Value.Trim() -eq $upd) ('{0} 变更记录末行日期 {1} == 最后更新' -f $id, $last.Groups[2].Value.Trim())
            $ascending = $true
            for ($i = 1; $i -lt $recs.Count; $i++) {
                if ([version]$recs[$i].Groups[1].Value.TrimStart('v') -le [version]$recs[$i - 1].Groups[1].Value.TrimStart('v')) { $ascending = $false }
            }
            Add-Result $ascending ('{0} 变更记录版本严格升序且不重复（共 {1} 行）' -f $id, $recs.Count)
        }
    }

    $md = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter *.md -File |
        Where-Object { ($_.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/') -notmatch '(^|/)(\.git|\.github|venv|node_modules|bin)/' } |
        ForEach-Object { $_.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/' })
    $unreg = @($md | Where-Object { $registered -notcontains $_ -and $_ -ne 'docs/01-文档台账.md' })
    Add-Result ($unreg.Count -eq 0) ('磁盘 Markdown 均已登记（未登记：{0}）' -f $(if ($unreg.Count) { $unreg -join '、' } else { '无' }))
    Add-Result ($md.Count -ge 15 -and $md.Count -le 60) ('扫描到的 Markdown 数量合理（{0}）' -f $md.Count)

    $scriptsDir = Join-Path -Path $RepoRoot -ChildPath 'scripts'
    $noBom = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $scriptsDir -Recurse -Filter *.ps1 -File)) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -eq 0 -or $bytes[0] -ne 0xEF) { $noBom.Add($file.Name) }
        }
    }
    Add-Result ($noBom.Count -eq 0) ('scripts 下 ps1 均带 UTF-8 BOM（缺失 {0}）' -f $noBom.Count)

    return ,$results
}

# 直接运行（pwsh -File / powershell -File）时输出结果并以退出码表示成败；被 dot-source 时不执行
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $auditResults = Get-McpLedgerAuditResult -RepoRoot $RepoRoot
    $auditFails = @($auditResults | Where-Object { -not $_.Ok })
    foreach ($item in $auditResults) {
        $prefix = if ($item.Ok) { 'PASS  ' } else { 'FAIL  ' }
        Write-Host ($prefix + $item.Message)
        if (-not $item.Ok -and $env:GITHUB_ACTIONS -eq 'true') { Write-Host ('::error::' + $item.Message) }
    }
    Write-Host ('结果: PASS={0} FAIL={1}' -f ($auditResults.Count - $auditFails.Count), $auditFails.Count)
    if ($auditFails.Count -gt 0) { exit 1 }
}
