[CmdletBinding()]
param(
    [Parameter()]
    [string] $Version = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$windowsDirectory = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $windowsDirectory "Cargo.toml"
$distDirectory = Join-Path $windowsDirectory "dist"
$publishDirectory = Join-Path $distDirectory "publish/WooTodo"

foreach ($requiredPath in @($manifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少 Windows 打包文件：$requiredPath"
    }
}
if ($null -eq (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "缺少 cargo 命令，请安装 Rust stable 工具链"
}

$metadataOutput = & cargo metadata `
    --manifest-path $manifestPath `
    --format-version 1 `
    --no-deps
if ($LASTEXITCODE -ne 0) {
    throw "cargo metadata 失败，退出码：$LASTEXITCODE"
}
$metadata = ($metadataOutput -join [Environment]::NewLine) | ConvertFrom-Json
$package = @($metadata.packages | Where-Object { $_.name -eq "woo-todo-windows" })
if ($package.Count -ne 1) {
    throw "无法从 Cargo.toml 唯一确定 woo-todo-windows 包"
}
$sourceVersion = ([string] $package[0].version).Trim()
if ($sourceVersion -notmatch "^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$") {
    throw "Cargo.toml 中的 version 不是规范稳定版本：$sourceVersion"
}

$packageVersion = if ([string]::IsNullOrWhiteSpace($Version)) {
    $sourceVersion
} else {
    $Version.Trim() -replace "^[vV]", ""
}
if ($packageVersion -ne $sourceVersion) {
    throw "请求打包的版本 $packageVersion 与源码版本 $sourceVersion 不一致"
}

$archiveName = "Woo-Todo-v$packageVersion-windows-x64-experimental.zip"
$archivePath = Join-Path $distDirectory $archiveName
$target = "x86_64-pc-windows-msvc"
$releaseExecutable = Join-Path ([string] $metadata.target_directory) "$target/release/WooTodo.exe"
$experimentalNotice = Join-Path $publishDirectory "WINDOWS-EXPERIMENTAL.txt"

# 仅清理脚本固定控制的 publish 目录，避免旧文件混入 ZIP。
if (Test-Path -LiteralPath $publishDirectory) {
    Remove-Item -LiteralPath $publishDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

Write-Host "正在生成 Rust + Win32 x64 原生可执行文件..."
& cargo build `
    --manifest-path $manifestPath `
    --bin WooTodo `
    --target $target `
    --release `
    --locked
if ($LASTEXITCODE -ne 0) {
    throw "cargo build 失败，退出码：$LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $releaseExecutable -PathType Leaf)) {
    throw "Rust Release 目录缺少 WooTodo.exe：$releaseExecutable"
}
Copy-Item -LiteralPath $releaseExecutable -Destination (Join-Path $publishDirectory "WooTodo.exe")
@"
Woo Todo Windows 实验版（不保证可用）

版本：v$packageVersion

此构建仅用于开发测试，不属于 Woo Todo 正式发布通道。
它可能无法启动、功能不完整，并可能存在稳定性或数据兼容风险。请勿将其用于唯一或重要任务数据。
后续 Windows 实验版需要手动下载并替换 WooTodo.exe。
"@ | Set-Content -LiteralPath $experimentalNotice -Encoding utf8

Write-Host "正在生成 Windows 10/11 x64 实验版（不保证可用）免安装 ZIP..."
Compress-Archive `
    -LiteralPath @(
        (Join-Path $publishDirectory "WooTodo.exe"),
        $experimentalNotice
    ) `
    -DestinationPath $archivePath `
    -CompressionLevel Optimal
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "没有生成 Windows ZIP：$archivePath"
}

Write-Host "Windows 实验版（不保证可用）免安装 ZIP 已生成：$archivePath"
