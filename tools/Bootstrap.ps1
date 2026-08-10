<#
.SYNOPSIS
    github-gems 一次性引导脚本：完成 落盘 token -> 建公开仓库 -> 关联 remote -> 首次推送。
    仅在首次配置时运行一次。

.DESCRIPTION
    用法：powershell -ExecutionPolicy Bypass -File tools\Bootstrap.ps1 -Token "<ghp_xxx>"
    可选：-RepoName github-gems -RepoDescription "每日 GitHub 新奇项目日报"

    脚本会：
      1. 校验 token 基本格式（ghp_ / github_pat_ 开头）
      2. 写入 $env:USERPROFILE\.config\opencode\github-gems.token
      3. 用 API 创建公开仓库（classic PAT 需 repo scope）
      4. 配置 remote origin 并推送 main 分支
      5. 用凭据管理器(GCM)缓存凭据，供每日定时任务非交互推送使用

.NOTES
    安全：token 只写入 .config\opencode\ 目录（仓库之外），绝不被 git 跟踪。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Token,
    [string]$RepoName = "github-gems",
    [string]$RepoDescription = "每日 GitHub 新奇项目日报：检索最近 7 天创建、star 1-49 的新奇项目",
    [string]$RepoDir = "C:\Users\Administrator\repos\github-gems",
    [string]$TokenFile = "$env:USERPROFILE\.config\opencode\github-gems.token"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# ---------- 1. 校验 token ----------
if ($Token -notmatch '^(ghp_|github_pat_)') {
    throw "Token 格式不正确：应以 ghp_ 或 github_pat_ 开头。请重新生成。"
}

# ---------- 2. 落盘 token ----------
$configDir = Split-Path -Parent $TokenFile
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($TokenFile, $Token.Trim() + "`n", (New-Object System.Text.UTF8Encoding $false))
Write-Host "token 已写入: $TokenFile" -ForegroundColor Green

# 确认 git 忽略规则兜底（若 .config 目录本身是 git 仓库）
if (Test-Path -LiteralPath (Join-Path $configDir '.git')) {
    $gi = git -C $configDir check-ignore (Split-Path -Leaf $TokenFile) 2>&1
    if (-not $gi) {
        Write-Warning "警告：.config\opencode 是 git 仓库且未忽略 token 文件！请在其中 .gitignore 添加: $(Split-Path -Leaf $TokenFile)"
    }
}

# ---------- 3. 创建公开仓库 ----------
$headers = @{
    'Authorization' = "token $Token"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'github-gems-bootstrap'
}
$body = @{ name = $RepoName; description = $RepoDescription; private = $false } | ConvertTo-Json

try {
    $null = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body -ContentType 'application/json'
    Write-Host "仓库已创建: https://github.com/<your-user>/$RepoName" -ForegroundColor Green
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 422) {
        Write-Host "仓库可能已存在（422），继续关联 remote..." -ForegroundColor Yellow
    }
    else {
        throw "创建仓库失败 (HTTP $status): $($_.Exception.Message)（classic PAT 需勾选 repo scope）"
    }
}

# ---------- 4. 配置 remote 并推送 ----------
Push-Location $RepoDir
try {
    # 用带 token 的 URL 做首次推送并让 GCM 缓存（不落盘到 git config）
    git config remote.origin.url "https://github.com/$RepoName.git" 2>$null
    git remote remove origin 2>$null
    git remote add origin "https://github.com/$RepoName.git"
    git branch -M main

    # 用带 token 的 URL 触发推送（凭据管理器会缓存，之后定时任务可无交互推送）
    git -c credential.helper=manager push -u "https://$Token@github.com/$RepoName.git" main
    Write-Host "首次推送完成！" -ForegroundColor Green
}
finally {
    Pop-Location
}

# ---------- 5. 清理 ----------
Write-Host ""
Write-Host "后续步骤：" -ForegroundColor Cyan
Write-Host "  1) 建议把 token 有效期记到日历，过期后更新 $TokenFile"
Write-Host "  2) 定时任务已注册：每天 12:00 主任务 + 12:30 重试哨兵（Asia/Shanghai）"
Write-Host "  3) 可手动触发：openchamber schedule.run（taskId 见会话记录）"
