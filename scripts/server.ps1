# Server cục bộ cho website + trang "Đăng chương" (dang-chuong.html).
#
# Chạy (từ thư mục dự án):
#   powershell -ExecutionPolicy Bypass -File scripts\server.ps1
# rồi mở http://localhost:8080/  (Ctrl+C để dừng)
#
# - Phục vụ file tĩnh của website (thay cho việc mở file:// trực tiếp).
# - POST /api/preview?name=<file.docx>   body = nội dung .docx
#     -> lưu tạm vào .upload-tmp/, chạy import-docx.ps1 -PreviewFile, trả về danh sách chương.
# - POST /api/publish   body = {"slug","files":[{"token","name"}],"touchDate":true}
#     -> chuyển file vào raw/, thêm vào sourceFiles trong meta.json, chạy import-docx.ps1.
#        Nếu import lỗi thì khôi phục meta.json và xoá các file vừa thêm.
#        Nếu "push": true -> commit content/ + data/ rồi git push (web GitHub Pages tự cập nhật).
# - POST /api/push  -> thử commit + push lại (khi lần trước lỗi mạng...).
#
# Chỉ lắng nghe trên localhost. Các POST bắt buộc có header X-Admin: 1 và Origin là
# localhost để trang web lạ không thể gửi request giả tới server này.
#
# LƯU Ý: file này phải lưu dạng UTF-8 có BOM (Windows PowerShell 5.1).

param(
  [int]$Port = 8080,
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$ImportScript = Join-Path $PSScriptRoot 'import-docx.ps1'
$TmpDir = Join-Path $Root '.upload-tmp'
$RawDir = Join-Path $Root 'raw'
$utf8 = New-Object Text.UTF8Encoding($false)

$Mime = @{
  '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.md' = 'text/markdown; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
  '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.gif' = 'image/gif'
  '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'
}

# ---------- JSON helpers ----------
function ConvertTo-JsonString([string]$s) {
  '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t') + '"'
}

# Ghi meta.json dễ đọc (ConvertTo-Json của PS 5.1 thụt lề rất xấu).
function ConvertTo-PrettyJson($v, [string]$indent = '') {
  $next = $indent + '  '
  if ($null -eq $v) { return 'null' }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [string]) { return ConvertTo-JsonString $v }
  if ($v -is [ValueType]) { return [string]$v }
  if ($v -is [Collections.IList]) {
    $items = @($v | ForEach-Object { ConvertTo-PrettyJson $_ $next })
    if ($items.Count -eq 0) { return '[]' }
    $oneLine = '[' + ($items -join ', ') + ']'
    if ($oneLine.Length -le 70) { return $oneLine }
    return "[`n$next" + ($items -join ",`n$next") + "`n$indent]"
  }
  $props = @($v.PSObject.Properties | ForEach-Object { (ConvertTo-JsonString $_.Name) + ': ' + (ConvertTo-PrettyJson $_.Value $next) })
  return "{`n$next" + ($props -join ",`n$next") + "`n$indent}"
}

# ---------- HTTP helpers ----------
function Send-Bytes($ctx, [int]$status, [string]$type, [byte[]]$bytes) {
  $res = $ctx.Response
  $res.StatusCode = $status
  $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}
function Send-Json($ctx, [int]$status, [string]$json) {
  Send-Bytes $ctx $status 'application/json; charset=utf-8' $utf8.GetBytes($json)
}
function Send-Error($ctx, [int]$status, [string]$msg, $log = @()) {
  $logJson = '[' + (@($log | ForEach-Object { ConvertTo-JsonString "$_" }) -join ',') + ']'
  Send-Json $ctx $status ('{"ok":false,"error":' + (ConvertTo-JsonString $msg) + ',"log":' + $logJson + '}')
}
# Đọc query string theo UTF-8 (HttpListener.QueryString không giải mã tiếng Việt đúng).
function Get-Query($req, [string]$key) {
  foreach ($pair in $req.Url.Query.TrimStart('?').Split('&')) {
    $kv = $pair.Split('=', 2)
    if ($kv[0] -eq $key -and $kv.Count -eq 2) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
  }
  return $null
}
# ---------- Git: tự đẩy lên GitHub sau khi đăng ----------
# Chạy git bằng Process riêng: PowerShell 5.1 coi stderr của git là lỗi khi $ErrorActionPreference = Stop.
function Invoke-Git([string[]]$GitArgs, [int]$TimeoutSec = 120) {
  $psi = New-Object Diagnostics.ProcessStartInfo 'git'
  $psi.Arguments = ($GitArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'   # không treo chờ nhập mật khẩu
  $p = [Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ code = -1; out = "git $($GitArgs[0]) quá $TimeoutSec giây, đã dừng." }
  }
  $p.WaitForExit()
  return @{ code = $p.ExitCode; out = ($outTask.Result + "`n" + $errTask.Result).Trim() }
}

# Commit những thay đổi trong content/ và data/ (không đụng file khác) rồi push.
function Publish-ToGit([string]$message) {
  $r = @{ ok = $false; skipped = $false; message = ''; detail = ''; pagesUrl = '' }
  if (-not (Test-Path (Join-Path $Root '.git'))) { $r.skipped = $true; $r.message = 'Thư mục dự án chưa phải git repo nên không đẩy lên GitHub.'; return $r }
  $remote = Invoke-Git @('remote', 'get-url', 'origin')
  if ($remote.code -ne 0) { $r.skipped = $true; $r.message = 'Repo chưa có remote "origin" nên không đẩy lên GitHub.'; return $r }
  if ($remote.out -match 'github\.com[:/]([^/]+)/([^/\s]+?)(\.git)?$') { $r.pagesUrl = "https://$($Matches[1].ToLower()).github.io/$($Matches[2])/" }

  $add = Invoke-Git @('add', '-A', '--', 'content', 'data')
  if ($add.code -ne 0) { $r.message = 'git add thất bại.'; $r.detail = $add.out; return $r }
  $diff = Invoke-Git @('diff', '--cached', '--quiet', '--', 'content', 'data')
  if ($diff.code -eq 1) {
    if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory $TmpDir | Out-Null }
    $msgFile = Join-Path $TmpDir 'commit-msg.txt'
    [IO.File]::WriteAllText($msgFile, $message + "`n", $utf8)
    $commit = Invoke-Git @('commit', '-q', '-F', $msgFile, '--', 'content', 'data')
    Remove-Item -LiteralPath $msgFile -ErrorAction SilentlyContinue
    if ($commit.code -ne 0) { $r.message = 'git commit thất bại.'; $r.detail = $commit.out; return $r }
  }
  $push = Invoke-Git @('push', 'origin', 'HEAD') 180
  if ($push.code -ne 0) {
    $r.message = 'Chương đã lưu trên máy nhưng chưa đẩy được lên GitHub.'
    if ($push.out -match 'rejected|fetch first|non-fast-forward') { $r.message += ' Repo trên GitHub có thay đổi mà máy chưa có, cần chạy "git pull" trước.' }
    elseif ($push.out -match 'Could not resolve host|unable to access') { $r.message += ' Kiểm tra lại kết nối mạng.' }
    elseif ($push.out -match 'Authentication|could not read Username|403') { $r.message += ' Cần đăng nhập lại GitHub (chạy "git push" trong PowerShell một lần).' }
    $r.detail = $push.out
    return $r
  }
  $r.ok = $true
  $r.message = 'Đã đẩy lên GitHub.'
  return $r
}

function ConvertTo-PushJson($r) {
  '{"ok":' + $(if ($r.ok) { 'true' } else { 'false' }) + ',"skipped":' + $(if ($r.skipped) { 'true' } else { 'false' }) +
  ',"message":' + (ConvertTo-JsonString $r.message) + ',"detail":' + (ConvertTo-JsonString $r.detail) +
  ',"pagesUrl":' + (ConvertTo-JsonString $r.pagesUrl) + '}'
}

function Invoke-Push($ctx) {
  $r = Publish-ToGit "Cập nhật chương truyện ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))"
  Send-Json $ctx 200 (ConvertTo-PushJson $r)
}

function Get-SafeDocxName([string]$name) {
  $n = [IO.Path]::GetFileName("$name")
  if (-not $n -or $n -notmatch '\.docx$' -or $n.StartsWith('.')) { return $null }
  return $n
}

# ---------- API ----------
function Invoke-Preview($ctx) {
  $name = Get-SafeDocxName (Get-Query $ctx.Request 'name')
  if (-not $name) { return Send-Error $ctx 400 'Chỉ nhận file .docx' }
  if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory $TmpDir | Out-Null }
  $token = [guid]::NewGuid().ToString('N')
  $tmp = Join-Path $TmpDir "$token.docx"
  $fs = [IO.File]::Create($tmp)
  try { $ctx.Request.InputStream.CopyTo($fs) } finally { $fs.Close() }
  try {
    $json = (& $ImportScript -Root $Root -PreviewFile $tmp) -join ''
  } catch {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return Send-Error $ctx 400 "Không đọc được file $name (có phải file Word .docx hợp lệ?): $($_.Exception.Message)"
  }
  Send-Json $ctx 200 ('{"ok":true,"token":"' + $token + '","name":' + (ConvertTo-JsonString $name) + ',"chapters":' + $json + '}')
}

function Invoke-Publish($ctx) {
  $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $utf8)
  $body = $reader.ReadToEnd() | ConvertFrom-Json
  $reader.Close()

  $slug = "$($body.slug)"
  if ($slug -notmatch '^[a-z0-9-]+$') { return Send-Error $ctx 400 'Slug không hợp lệ' }
  $storyDir = Join-Path $Root "content\truyen\$slug"
  $metaPath = Join-Path $storyDir 'meta.json'
  if (-not (Test-Path -LiteralPath $metaPath)) { return Send-Error $ctx 404 "Không tìm thấy truyện $slug" }
  $files = @($body.files)
  if ($files.Count -eq 0) { return Send-Error $ctx 400 'Chưa chọn file nào' }

  # Kiểm tra toàn bộ trước khi đụng vào file thật.
  foreach ($f in $files) {
    if ("$($f.token)" -notmatch '^[a-f0-9]{32}$' -or -not (Get-SafeDocxName $f.name)) { return Send-Error $ctx 400 'Dữ liệu file không hợp lệ' }
    if (-not (Test-Path -LiteralPath (Join-Path $TmpDir "$($f.token).docx"))) { return Send-Error $ctx 400 "File tạm của $($f.name) đã hết hạn, hãy chọn lại file." }
  }

  $before = @(Get-ChildItem (Join-Path $storyDir 'chuong-*.md') -ErrorAction SilentlyContinue | ForEach-Object { [int]($_.BaseName -replace '\D', '') })
  $metaBackup = [IO.File]::ReadAllText($metaPath, $utf8)
  $meta = $metaBackup | ConvertFrom-Json
  if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory $RawDir | Out-Null }

  $created = @(); $replacedBackups = @{}
  foreach ($f in $files) {
    $name = Get-SafeDocxName $f.name
    $dest = Join-Path $RawDir $name
    if (Test-Path -LiteralPath $dest) {
      $bak = "$dest.bak"; Copy-Item -LiteralPath $dest $bak -Force; $replacedBackups[$dest] = $bak
    } else { $created += $dest }
    Move-Item -LiteralPath (Join-Path $TmpDir "$($f.token).docx") $dest -Force
    if (@($meta.sourceFiles) -notcontains $name) { $meta.sourceFiles = @($meta.sourceFiles) + $name }
  }
  if ($body.touchDate) { $meta.updatedAt = (Get-Date).ToString('yyyy-MM-dd') }
  [IO.File]::WriteAllText($metaPath, (ConvertTo-PrettyJson $meta) + "`n", $utf8)

  $log = @()
  try {
    $log = @(& $ImportScript -Root $Root *>&1 | ForEach-Object {
      if ($_ -is [Management.Automation.WarningRecord]) { "CẢNH BÁO: $($_.Message)" } else { "$_" }
    })
  } catch {
    # Khôi phục trạng thái cũ.
    [IO.File]::WriteAllText($metaPath, $metaBackup, $utf8)
    $created | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
    $replacedBackups.GetEnumerator() | ForEach-Object { Move-Item -LiteralPath $_.Value $_.Key -Force }
    return Send-Error $ctx 500 "Import thất bại, đã khôi phục như cũ: $($_.Exception.Message)" $log
  }
  $replacedBackups.Values | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }

  $nums = @(Get-ChildItem (Join-Path $storyDir 'chuong-*.md') | ForEach-Object { [int]($_.BaseName -replace '\D', '') } | Sort-Object)
  $logJson = '[' + (@($log | ForEach-Object { ConvertTo-JsonString $_ }) -join ',') + ']'

  # Tự đẩy lên GitHub (nếu được bật).
  $pushJson = 'null'
  if ($body.push) {
    $added = @($nums | Where-Object { $before -notcontains $_ })
    $what = if ($added.Count -eq 0) { 'Cập nhật chương' }
            elseif ($added.Count -eq 1) { "Đăng chương $($added[0])" }
            else { "Đăng chương $($added[0])-$($added[-1])" }
    $pushJson = ConvertTo-PushJson (Publish-ToGit "${what}: $($meta.title)")
  }
  Send-Json $ctx 200 ('{"ok":true,"total":' + $nums.Count + ',"last":' + $(if ($nums.Count) { $nums[-1] } else { 0 }) + ',"log":' + $logJson + ',"push":' + $pushJson + '}')
}

# ---------- Static files ----------
function Send-Static($ctx, [string]$path) {
  $rel = $path.TrimStart('/').Replace('/', '\')
  if (-not $rel) { $rel = 'index.html' }
  $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
  if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { return Send-Error $ctx 403 'Forbidden' }
  if (Test-Path -LiteralPath $full -PathType Container) { $full = Join-Path $full 'index.html' }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    return Send-Bytes $ctx 404 'text/html; charset=utf-8' $utf8.GetBytes('<h1>404</h1><p>Không tìm thấy trang. <a href="/">Về trang chủ</a></p>')
  }
  $ext = [IO.Path]::GetExtension($full).ToLower()
  $type = if ($Mime.ContainsKey($ext)) { $Mime[$ext] } else { 'application/octet-stream' }
  Send-Bytes $ctx 200 $type ([IO.File]::ReadAllBytes($full))
}

function Invoke-Request($ctx) {
  $req = $ctx.Request
  $path = [Uri]::UnescapeDataString($req.Url.AbsolutePath)
  if ($path.StartsWith('/api/')) {
    if ($req.HttpMethod -eq 'POST') {
      $origin = $req.Headers['Origin']
      if ($req.Headers['X-Admin'] -ne '1' -or ($origin -and $origin -notmatch '^http://(localhost|127\.0\.0\.1)(:\d+)?$')) {
        return Send-Error $ctx 403 'Request bị từ chối'
      }
    }
    if ($path -eq '/api/ping') { return Send-Json $ctx 200 '{"ok":true}' }
    if ($path -eq '/api/preview' -and $req.HttpMethod -eq 'POST') { return Invoke-Preview $ctx }
    if ($path -eq '/api/publish' -and $req.HttpMethod -eq 'POST') { return Invoke-Publish $ctx }
    if ($path -eq '/api/push' -and $req.HttpMethod -eq 'POST') { return Invoke-Push $ctx }
    return Send-Error $ctx 404 'API không tồn tại'
  }
  if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'HEAD') { return Send-Error $ctx 405 'Method not allowed' }
  Send-Static $ctx $path
}

# ---------- Main loop ----------
if (Test-Path $TmpDir) { Get-ChildItem $TmpDir -File | Remove-Item -ErrorAction SilentlyContinue }  # dọn file tạm cũ
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Website:      http://localhost:$Port/"
Write-Host "Đăng chương:  http://localhost:$Port/dang-chuong.html"
Write-Host "Nhấn Ctrl+C để dừng server."
try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(300)) { }   # chờ ngắn để Ctrl+C hoạt động
    $ctx = $task.GetAwaiter().GetResult()
    Write-Host ("{0:HH:mm:ss} {1} {2}" -f (Get-Date), $ctx.Request.HttpMethod, $ctx.Request.Url.PathAndQuery)
    try { Invoke-Request $ctx }
    catch {
      Write-Warning $_.Exception.Message
      try { Send-Error $ctx 500 $_.Exception.Message } catch { }
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
