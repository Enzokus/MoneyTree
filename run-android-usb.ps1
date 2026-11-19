param([string]$DeviceId)
$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
$taskAdbCommand = Get-Command adb -ErrorAction SilentlyContinue
$taskAdb = if ($taskAdbCommand) { $taskAdbCommand.Source } else {
    Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
}
if (!(Test-Path -LiteralPath $taskAdb)) { throw 'Android platform-tools (adb) не найдены.' }
$taskApk = Join-Path $taskRoot 'subscription_tree-android-usb.apk'
if (!(Test-Path -LiteralPath $taskApk)) { throw "Не найден APK: $taskApk" }
$taskDevices = @(& $taskAdb devices | ForEach-Object {
    if ($_ -match '^(\S+)\s+device\s*$' -and $Matches[1] -notlike 'emulator-*') { $Matches[1] }
})
if ($DeviceId) {
    if ($DeviceId -notin $taskDevices) { throw 'Указанный физический Android не подключён или не разрешена отладка.' }
    $taskDevice = $DeviceId
} elseif ($taskDevices.Count -eq 1) {
    $taskDevice = $taskDevices[0]
} elseif ($taskDevices.Count -eq 0) {
    & $taskAdb devices -l
    throw 'Подключите телефон по USB, включите отладку по USB и подтвердите разрешение на экране телефона. Затем запустите этот файл ещё раз.'
} else {
    throw 'Подключено несколько телефонов. Запустите с параметром -DeviceId (идентификатор из adb devices).'
}
function Test-TaskBackend {
    try {
        $taskSchema = Invoke-RestMethod 'http://127.0.0.1:8000/openapi.json' -TimeoutSec 2
        return $taskSchema.info.title -eq 'Subscription Tree API' -and $null -ne $taskSchema.paths.'/auth/login'
    } catch { return $false }
}
if (!(Test-TaskBackend)) {
    $taskBackend = Join-Path $taskRoot 'backend'
    $taskPython = Join-Path $taskBackend '.venv/Scripts/python.exe'
    if (!(Test-Path -LiteralPath $taskPython)) { throw 'Не найден Python сервера: backend/.venv/Scripts/python.exe' }
    $taskPreviousDevAuth = $env:ALLOW_DEV_AUTH
    try {
        $env:ALLOW_DEV_AUTH = 'true'
        Start-Process -FilePath $taskPython -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', '8000') -WorkingDirectory $taskBackend -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskBackend 'server-usb.log') -RedirectStandardError (Join-Path $taskBackend 'server-usb-error.log') | Out-Null
    } finally { $env:ALLOW_DEV_AUTH = $taskPreviousDevAuth }
    for ($taskAttempt = 0; $taskAttempt -lt 20; $taskAttempt++) {
        if (Test-TaskBackend) { break }
        Start-Sleep -Milliseconds 250
    }
    if (!(Test-TaskBackend)) { throw 'Сервер не запустился. Подробности: backend/server-usb-error.log' }
}
& $taskAdb -s $taskDevice reverse tcp:8000 tcp:8000
if ($LASTEXITCODE -ne 0) { throw 'Не удалось настроить подключение телефона к серверу через USB.' }
& $taskAdb -s $taskDevice install -r $taskApk
if ($LASTEXITCODE -ne 0) { throw 'Не удалось установить APK. Проверьте подтверждение установки на телефоне.' }
& $taskAdb -s $taskDevice shell am start -n com.example.subscription_tree/.MainActivity
if ($LASTEXITCODE -ne 0) { throw 'Не удалось открыть приложение.' }
Write-Host 'Готово. На телефоне войдите с тестовым телефоном или почтой и паролем из README. Для синхронизации оставьте USB подключённым и сервер запущенным.'
