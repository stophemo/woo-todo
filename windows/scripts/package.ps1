[CmdletBinding()]
param(
    [Parameter()]
    [string] $Version = "",

    [Parameter()]
    [ValidateSet("win-x64")]
    [string] $Runtime = "win-x64",

    [Parameter()]
    [string] $IsccPath = "",

    [Parameter()]
    [switch] $NoRestore
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$windowsDirectory = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $windowsDirectory "src/WooTodo.WindowsApp/WooTodo.WindowsApp.csproj"
$propsPath = Join-Path $windowsDirectory "Directory.Build.props"
$installerScript = Join-Path $windowsDirectory "installer/WooTodo.iss"
$iconPath = Join-Path $windowsDirectory "src/WooTodo.WindowsApp/Assets/WooTodo.ico"
$distDirectory = Join-Path $windowsDirectory "dist"
$publishDirectory = Join-Path $distDirectory "publish/WooTodo"

foreach ($requiredPath in @($projectPath, $propsPath, $installerScript, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "缺少 Windows 打包文件：$requiredPath"
    }
}
if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "缺少 dotnet 命令，请安装 .NET 10 SDK"
}

[xml] $buildProps = Get-Content -LiteralPath $propsPath -Raw
$sourceVersion = [string] (
    $buildProps.Project.PropertyGroup |
        ForEach-Object { $_.Version } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        Select-Object -First 1
)
$sourceVersion = $sourceVersion.Trim()
if ($sourceVersion -notmatch "^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$") {
    throw "Directory.Build.props 中的 Version 不是规范稳定版本：$sourceVersion"
}

$packageVersion = if ([string]::IsNullOrWhiteSpace($Version)) {
    $sourceVersion
} else {
    $Version.Trim() -replace "^[vV]", ""
}
if ($packageVersion -ne $sourceVersion) {
    throw "请求打包的版本 $packageVersion 与源码版本 $sourceVersion 不一致"
}

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $IsccPath = $command.Source
    } else {
        $candidates = @(
            (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe"),
            (Join-Path $env:ProgramFiles "Inno Setup 6/ISCC.exe")
        )
        $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
}
if ([string]::IsNullOrWhiteSpace($IsccPath) -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw "缺少 Inno Setup 6 编译器 ISCC.exe"
}

$installerName = "Woo-Todo-v$packageVersion-windows-x64-setup.exe"
$installerPath = Join-Path $distDirectory $installerName

if (-not $NoRestore) {
    Write-Host "正在按 packages.lock.json 还原 Windows 依赖..."
    & dotnet restore $projectPath `
        --runtime $Runtime `
        --locked-mode `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet restore 失败，退出码：$LASTEXITCODE"
    }
}

# 仅清理脚本固定控制的 publish 目录，避免旧文件混入安装包。
if (Test-Path -LiteralPath $publishDirectory) {
    Remove-Item -LiteralPath $publishDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null
if (Test-Path -LiteralPath $installerPath) {
    Remove-Item -LiteralPath $installerPath -Force
}

Write-Host "正在生成 .NET 10 $Runtime 自包含应用目录..."
& dotnet publish $projectPath `
    --configuration Release `
    --runtime $Runtime `
    --self-contained true `
    --output $publishDirectory `
    --no-restore `
    --nologo `
    -p:PublishSingleFile=false `
    -p:PublishTrimmed=false
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish 失败，退出码：$LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory "WooTodo.exe") -PathType Leaf)) {
    throw "发布目录缺少 WooTodo.exe：$publishDirectory"
}

Write-Host "正在生成 Windows 10/11 EXE 安装包..."
& $IsccPath `
    "/DAppVersion=$packageVersion" `
    "/DSourceDir=$publishDirectory" `
    "/DOutputDir=$distDirectory" `
    "/DIconPath=$iconPath" `
    $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup 编译失败，退出码：$LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "没有生成 Windows 安装包：$installerPath"
}

Write-Host "Windows EXE 安装包已生成：$installerPath"
