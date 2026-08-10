<#
.SYNOPSIS
    检索 GitHub 上最近创建的"新奇"新项目（star < 50、非 fork、排除教程/awesome 类）。
    只做检索与粗过滤，不做 AI 语义判断。输出 JSON 到 stdout。

.DESCRIPTION
    - 读取 token 自 $env:USERPROFILE\.config\opencode\github-gems.token（一行）
    - 查询条件: created:>N天前 stars:<50 fork:false
    - 注意: GitHub Search API 不支持 sort=created，因此在客户端按 created_at 降序重排后取前 MaxCandidates 个
    - 粗过滤: 排除 name/description/topics 命中 教程/awesome/tutorial/course 等关键词的项目
    - 输出: JSON 对象 { query, fetched_at, total_count, candidates: [...] }

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Search-NewRepos.ps1 -DaysBack 7 -MaxCandidates 50
#>

[CmdletBinding()]
param(
    [int]$DaysBack = 7,
    [int]$MaxCandidates = 50,
    [int]$PerPage = 100,
    [string]$TokenFile = "$env:USERPROFILE\.config\opencode\github-gems.token",
    [string]$OutFile = ""
)

# PowerShell 5.1 强制 TLS 1.2，并统一 UTF-8 输出
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ---------- 读取 token ----------
if (-not (Test-Path -LiteralPath $TokenFile)) {
    throw "Token 文件不存在: $TokenFile（请创建并写入一行 GitHub Personal Access Token）"
}
$token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
if ($token.Length -lt 20) {
    throw "Token 内容过短（<20 字符），请检查 $TokenFile 是否为一整行有效 PAT。"
}

$headers = @{
    'Authorization' = "token $token"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'github-gems-daily-hunt'
}

# ---------- 构造查询 ----------
$since = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-dd')
# stars:1..49 排除 0 星垃圾仓库（实测 0 星多为空壳/乱码名仓库，质量差），
# 注意 stars:>=1 stars:<50 的 >= 写法会被 GitHub 忽略，必须用区间写法 1..49
$q = "created:>$since stars:1..49 fork:false"
$uri = "https://api.github.com/search/repositories?q=$([Uri]::EscapeDataString($q))&sort=updated&order=desc&per_page=$PerPage"

# ---------- 带退避重试的请求 ----------
function Invoke-GitHubWithRetry {
    param([string]$Uri, [hashtable]$Headers, [int]$MaxRetries = 3)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -in 403, 429 -and $attempt -le $MaxRetries) {
                $wait = [Math]::Pow(2, $attempt) * 5   # 5s, 10s, 20s
                Write-Warning "请求被限流(HTTP $status)，$wait 秒后重试 ($attempt/$MaxRetries)..."
                Start-Sleep -Seconds $wait
            }
            else {
                throw
            }
        }
    }
}

Write-Host "查询: $q" -ForegroundColor Cyan
$resp = Invoke-GitHubWithRetry -Uri $uri -Headers $headers
Write-Host "API total_count: $($resp.total_count)" -ForegroundColor Gray

# ---------- 粗过滤 + 客户端按创建时间重排 ----------
$excludePattern = 'awesome|tutorial|course|roadmap|interview|cheatsheet|learning|示例|教程|练习|template|boilerplate|starter|^learn-|^awesome-'

$candidates = $resp.items |
    Where-Object { -not $_.fork } |
    Where-Object {
        $haystack = "$($_.name) $($_.description) $($_.topics -join ' ')"
        $haystack -notmatch $excludePattern
    } |
    Sort-Object { [datetime]$_.created_at } -Descending |
    Select-Object -First $MaxCandidates |
    ForEach-Object {
        [PSCustomObject]@{
            full_name         = $_.full_name
            html_url          = $_.html_url
            description       = $_.description
            stargazers_count  = $_.stargazers_count
            language          = $_.language
            created_at        = $_.created_at
            topics            = ($_.topics -join ',')
            default_branch    = $_.default_branch
        }
    }

if ($resp.total_count -ge 1000) {
    Write-Warning "total_count >= 1000，可能超过 Search API 单查询上限，结果不完整。"
}

$out = [PSCustomObject]@{
    query       = $q
    fetched_at  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    total_count = $resp.total_count
    candidates  = @($candidates)
}

$json = $out | ConvertTo-Json -Depth 5
if ($OutFile) {
    $json | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host "已写入 $OutFile（候选 $($candidates.Count) 个）" -ForegroundColor Green
}
else {
    $json
}
