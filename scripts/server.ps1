# Server cục bộ cho website + trang quản lý "Đăng & quản lý truyện" (dang-truyen.html).
#
# Chạy (từ thư mục dự án):
#   powershell -ExecutionPolicy Bypass -File scripts\server.ps1
# rồi mở http://localhost:8080/dang-truyen.html  (Ctrl+C để dừng)
#
# API (mọi POST bắt buộc header X-Admin: 1 và Origin là localhost):
#   GET  /api/stories                          danh sách truyện (kể cả truyện chưa có chương)
#   GET  /api/story?slug=                      thông tin truyện + danh sách chương
#   POST /api/story/save      {slug,isNew,title,author,translator,genres,status,description,featured,removeCover,push}
#   POST /api/story/cover?slug=&ext=&push=     body = ảnh bìa (jpg/png/webp, <= 8MB)
#   POST /api/story/delete    {slug,confirm:true,push}
#   POST /api/chapter/update  {slug,n,newN,title,push}   đổi tên / đổi số chương
#   POST /api/chapter/delete  {slug,n,push}
#   POST /api/preview?name=                    body = .docx -> danh sách chương tìm thấy (không ghi gì)
#   POST /api/publish         {slug,files:[{token,name}],touchDate,push}  nhập chương từ file đã preview
#   POST /api/push                             thử commit + push lại
#
# Mỗi thao tác ghi: sao lưu thư mục truyện + data/stories.js trước, lỗi thì khôi phục.
# "push": true -> commit content/ + data/ rồi git push (GitHub Pages tự cập nhật).
#
# LƯU Ý: file này phải lưu dạng UTF-8 có BOM (Windows PowerShell 5.1).

param(
  [int]$Port = 8080,
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
. (Join-Path $PSScriptRoot 'content-lib.ps1')
$TmpDir = Join-Path $Root '.upload-tmp'
$RawDir = Join-Path $Root 'raw'
$MaxCoverBytes = 8MB

$Mime = @{
  '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'; '.md' = 'text/markdown; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
  '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.webp' = 'image/webp'; '.gif' = 'image/gif'
  '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'
}

function Get-Today { (Get-Date).ToString('yyyy-MM-dd') }

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
function Send-Obj($ctx, [int]$status, $obj) {
  Send-Bytes $ctx $status 'application/json; charset=utf-8' $Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $obj -Depth 10 -Compress))
}
function Send-Error($ctx, [int]$status, [string]$msg) {
  Send-Obj $ctx $status ([ordered]@{ ok = $false; error = $msg })
}
# Đọc query string theo UTF-8 (HttpListener.QueryString không giải mã tiếng Việt đúng).
function Get-Query($req, [string]$key) {
  foreach ($pair in $req.Url.Query.TrimStart('?').Split('&')) {
    $kv = $pair.Split('=', 2)
    if ($kv[0] -eq $key -and $kv.Count -eq 2) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
  }
  return $null
}
function Read-JsonBody($ctx) {
  $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8NoBom)
  try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
  if (-not $text.Trim()) { return [pscustomobject]@{} }
  return $text | ConvertFrom-Json
}
function Read-BodyBytes($ctx, [long]$max) {
  $ms = New-Object IO.MemoryStream
  $buf = New-Object byte[] 65536
  $in = $ctx.Request.InputStream
  while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
    $ms.Write($buf, 0, $read)
    if ($ms.Length -gt $max) { throw "File quá lớn (tối đa $([int]($max / 1MB)) MB)." }
  }
  return $ms.ToArray()
}
function Get-SafeDocxName([string]$name) {
  $n = [IO.Path]::GetFileName("$name")
  if (-not $n -or $n -notmatch '\.docx$' -or $n.StartsWith('.')) { return $null }
  return $n
}
function ConvertTo-ChapterNumber($v) {
  $i = 0
  if ([int]::TryParse("$v", [ref]$i) -and $i -ge 1 -and $i -le 99999) { return $i }
  throw "Số chương không hợp lệ: '$v' (phải là số nguyên từ 1 đến 99999)."
}
function Assert-Slug([string]$slug) {
  if ($slug -notmatch $SlugRe -or $slug.Length -gt 80) { throw 'Đường dẫn (slug) chỉ gồm chữ thường không dấu, số và dấu gạch ngang, tối đa 80 ký tự.' }
}
function Test-StoryExists([string]$slug) { Test-Path -LiteralPath (Join-Path (Get-StoryDir $Root $slug) 'meta.json') }

# ---------- Git: tự đẩy lên GitHub ----------
# Chạy git bằng Process riêng: PowerShell 5.1 coi stderr của git là lỗi khi $ErrorActionPreference = Stop.
function Invoke-Git([string[]]$GitArgs, [int]$TimeoutSec = 120) {
  $psi = New-Object Diagnostics.ProcessStartInfo 'git'
  $psi.Arguments = ($GitArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8NoBom
  $psi.StandardErrorEncoding = $Utf8NoBom
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
  $r = [ordered]@{ ok = $false; skipped = $false; message = ''; detail = ''; pagesUrl = '' }
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
    [IO.File]::WriteAllText($msgFile, $message + "`n", $Utf8NoBom)
    $commit = Invoke-Git @('commit', '-q', '-F', $msgFile, '--', 'content', 'data')
    Remove-Item -LiteralPath $msgFile -ErrorAction SilentlyContinue
    if ($commit.code -ne 0) { $r.message = 'git commit thất bại.'; $r.detail = $commit.out; return $r }
  }
  $push = Invoke-Git @('push', 'origin', 'HEAD') 180
  if ($push.code -ne 0) {
    $r.message = 'Thay đổi đã lưu trên máy nhưng chưa đẩy được lên GitHub.'
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

# Kéo các thay đổi đã đăng từ trang quản lý trên web (chế độ đăng nhập GitHub) về máy trước khi đọc/ghi,
# để lần đẩy sau không bị GitHub từ chối. Chỉ fast-forward; lỗi (mất mạng, lệch nhánh) thì bỏ qua.
$script:LastSync = [datetime]::MinValue
function Sync-FromGit([switch]$Force) {
  if (-not (Test-Path (Join-Path $Root '.git'))) { return }
  if (-not $Force -and ((Get-Date) - $script:LastSync).TotalSeconds -lt 20) { return }
  $script:LastSync = Get-Date
  $r = Invoke-Git @('pull', '--ff-only', '-q') 30
  if ($r.code -ne 0) { Write-Warning "git pull bỏ qua: $(($r.out -split "`n")[0])" }
}

# ---------- Sao lưu / khôi phục cho mọi thao tác ghi ----------
function Backup-State([string]$slug) {
  $bak = Join-Path $TmpDir ('bak-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $bak -Force | Out-Null
  $dir = Get-StoryDir $Root $slug
  $snap = @{ bak = $bak; dir = $dir; hadDir = (Test-Path -LiteralPath $dir); bundle = (Join-Path $Root 'data\stories.js') }
  if ($snap.hadDir) { Copy-Item -LiteralPath $dir -Destination (Join-Path $bak 'story') -Recurse }
  if (Test-Path -LiteralPath $snap.bundle) { Copy-Item -LiteralPath $snap.bundle (Join-Path $bak 'stories.js') }
  return $snap
}
function Restore-State($snap) {
  if (Test-Path -LiteralPath $snap.dir) { Remove-Item -LiteralPath $snap.dir -Recurse -Force }
  if ($snap.hadDir) { Copy-Item -LiteralPath (Join-Path $snap.bak 'story') -Destination $snap.dir -Recurse }
  $b = Join-Path $snap.bak 'stories.js'
  if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b $snap.bundle -Force }
}

# Chạy $action (trả về hashtable có message, commit, ...). Lỗi -> khôi phục. Xong -> push nếu được yêu cầu.
function Invoke-Mutation($ctx, [string]$slug, [bool]$push, [scriptblock]$action) {
  Sync-FromGit
  $snap = Backup-State $slug
  try {
    $res = @(& $action)[-1]
  } catch {
    $err = $_.Exception.Message
    try { Restore-State $snap } catch { $err += " (Khôi phục cũng lỗi: $($_.Exception.Message))" }
    Remove-Item -LiteralPath $snap.bak -Recurse -Force -ErrorAction SilentlyContinue
    return Send-Error $ctx 500 "Thao tác thất bại, đã khôi phục như cũ. Lỗi: $err"
  }
  Remove-Item -LiteralPath $snap.bak -Recurse -Force -ErrorAction SilentlyContinue
  $out = [ordered]@{ ok = $true }
  foreach ($k in $res.Keys) { if ($k -ne 'commit') { $out[$k] = $res[$k] } }
  $out.push = if ($push) { Publish-ToGit $res.commit } else { $null }
  Send-Obj $ctx 200 $out
}

# ---------- API: đọc ----------
function Invoke-ListStories($ctx) {
  Sync-FromGit -Force
  $list = @(foreach ($metaFile in @(Get-ChildItem (Join-Path $Root 'content\truyen\*\meta.json') -ErrorAction SilentlyContinue)) {
    $slug = Split-Path -Leaf $metaFile.DirectoryName
    $meta = Read-Meta $Root $slug
    $nums = @(Get-ChapterNumbers $metaFile.DirectoryName)
    [ordered]@{
      slug = $slug; title = "$($meta.title)"; status = "$($meta.status)"; updatedAt = "$($meta.updatedAt)"
      genres = @($meta.genres); chapters = $nums.Count; last = $(if ($nums.Count) { $nums[-1] } else { 0 })
      cover = (Get-CoverUrl $Root $slug $meta)
    }
  })
  $list = @($list | Sort-Object { $_.updatedAt } -Descending)
  Send-Obj $ctx 200 ([ordered]@{ ok = $true; stories = $list })
}

function Invoke-GetStory($ctx) {
  $slug = "$(Get-Query $ctx.Request 'slug')"
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  $meta = Read-Meta $Root $slug
  $dir = Get-StoryDir $Root $slug
  $chapters = @(foreach ($n in @(Get-ChapterNumbers $dir)) {
    $c = Read-Chapter (Get-ChapterPath $dir $n)
    [ordered]@{ n = $c.n; title = $c.title; words = (Get-WordCount $c.paras); publishedAt = $c.publishedAt }
  })
  $story = [ordered]@{
    slug = $slug; title = "$($meta.title)"; author = "$($meta.author)"; translator = "$($meta.translator)"
    genres = @($meta.genres | Where-Object { $_ }); status = "$($meta.status)"; description = "$($meta.description)"
    featured = [bool]$meta.featured; updatedAt = "$($meta.updatedAt)"; cover = (Get-CoverUrl $Root $slug $meta)
  }
  Send-Obj $ctx 200 ([ordered]@{ ok = $true; story = $story; chapters = $chapters })
}

# ---------- API: truyện ----------
function Get-StoryFields($body) {
  $title = "$($body.title)".Trim()
  if (-not $title) { throw 'Tên truyện không được để trống.' }
  if ($title.Length -gt 200) { throw 'Tên truyện quá dài (tối đa 200 ký tự).' }
  $desc = "$($body.description)".Trim()
  if ($desc.Length -gt 5000) { throw 'Phần giới thiệu quá dài (tối đa 5000 ký tự).' }
  $genres = @(@($body.genres) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_.Length -le 40 } | Select-Object -Unique -First 20)
  return [ordered]@{
    title = $title
    author = "$($body.author)".Trim().Substring(0, [Math]::Min(120, "$($body.author)".Trim().Length))
    translator = "$($body.translator)".Trim().Substring(0, [Math]::Min(120, "$($body.translator)".Trim().Length))
    genres = $genres
    status = $(if ($body.status -eq 'hoan-thanh') { 'hoan-thanh' } else { 'dang-ra' })
    description = $desc
    featured = [bool]$body.featured
  }
}

function Invoke-SaveStory($ctx) {
  $body = Read-JsonBody $ctx
  $slug = "$($body.slug)".Trim().ToLower()
  $isNew = [bool]$body.isNew
  try { Assert-Slug $slug; $fields = Get-StoryFields $body } catch { return Send-Error $ctx 400 $_.Exception.Message }
  if ($isNew -and (Test-Path -LiteralPath (Get-StoryDir $Root $slug))) { return Send-Error $ctx 409 "Đã có truyện dùng đường dẫn '$slug'. Hãy đổi đường dẫn khác." }
  if (-not $isNew -and -not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }

  Invoke-Mutation $ctx $slug ([bool]$body.push) {
    $dir = Get-StoryDir $Root $slug
    if ($isNew) {
      New-Item -ItemType Directory $dir | Out-Null
      $meta = [pscustomobject][ordered]@{
        title = ''; slug = $slug; author = ''; translator = ''; genres = @(); status = 'dang-ra'
        description = ''; featured = $true; updatedAt = (Get-Today); sourceFiles = @()
      }
    } else { $meta = Read-Meta $Root $slug }
    foreach ($k in $fields.Keys) { Set-MetaProp $meta $k $fields[$k] }
    if ($body.removeCover -and $meta.cover) {
      Remove-Item -LiteralPath (Join-Path $dir $meta.cover) -ErrorAction SilentlyContinue
      $meta.PSObject.Properties.Remove('cover')
    }
    Write-Meta $Root $slug $meta
    [void](Build-Bundle $Root)
    @{
      message = $(if ($isNew) { "Đã tạo truyện ""$($fields.title)""." } else { 'Đã lưu thông tin truyện.' })
      slug = $slug
      commit = $(if ($isNew) { "Tạo truyện: $($fields.title)" } else { "Cập nhật thông tin truyện: $($fields.title)" })
    }
  }
}

function Invoke-SaveCover($ctx) {
  $req = $ctx.Request
  $slug = "$(Get-Query $req 'slug')"
  $ext = "$(Get-Query $req 'ext')".ToLower().TrimStart('.')
  if ($ext -eq 'jpeg') { $ext = 'jpg' }
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  if ($ext -notin 'jpg', 'png', 'webp') { return Send-Error $ctx 400 'Ảnh bìa chỉ nhận file .jpg, .png hoặc .webp.' }
  try { $bytes = Read-BodyBytes $ctx $MaxCoverBytes } catch { return Send-Error $ctx 400 $_.Exception.Message }
  $isImg = $bytes.Length -gt 12 -and (
    ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) -or
    ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) -or
    ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'RIFF' -and [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq 'WEBP'))
  if (-not $isImg) { return Send-Error $ctx 400 'File không phải ảnh JPG/PNG/WEBP hợp lệ.' }

  Invoke-Mutation $ctx $slug ((Get-Query $req 'push') -eq '1') {
    $dir = Get-StoryDir $Root $slug
    $meta = Read-Meta $Root $slug
    Get-ChildItem -LiteralPath $dir -Filter 'cover.*' | Remove-Item
    [IO.File]::WriteAllBytes((Join-Path $dir "cover.$ext"), $bytes)
    Set-MetaProp $meta 'cover' "cover.$ext"
    Write-Meta $Root $slug $meta
    [void](Build-Bundle $Root)
    @{ message = 'Đã cập nhật ảnh bìa.'; cover = (Get-CoverUrl $Root $slug $meta); commit = "Đổi ảnh bìa: $($meta.title)" }
  }
}

function Invoke-DeleteStory($ctx) {
  $body = Read-JsonBody $ctx
  $slug = "$($body.slug)"
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  if ($body.confirm -ne $true) { return Send-Error $ctx 400 'Thiếu xác nhận xoá truyện.' }
  $title = (Read-Meta $Root $slug).title
  Invoke-Mutation $ctx $slug ([bool]$body.push) {
    Remove-Item -LiteralPath (Get-StoryDir $Root $slug) -Recurse -Force
    [void](Build-Bundle $Root)
    @{ message = "Đã xoá truyện ""$title""."; commit = "Xoá truyện: $title" }
  }
}

# ---------- API: chương ----------
function Invoke-UpdateChapter($ctx) {
  $body = Read-JsonBody $ctx
  $slug = "$($body.slug)"
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  try {
    $n = ConvertTo-ChapterNumber $body.n
    $newN = ConvertTo-ChapterNumber $body.newN
    $title = ("$($body.title)" -replace '[\r\n\t]+', ' ').Trim()
    if (-not $title) { throw 'Tên chương không được để trống.' }
    if ($title.Length -gt 200) { throw 'Tên chương quá dài (tối đa 200 ký tự).' }
  } catch { return Send-Error $ctx 400 $_.Exception.Message }
  $dir = Get-StoryDir $Root $slug
  $src = Get-ChapterPath $dir $n
  if (-not (Test-Path -LiteralPath $src)) { return Send-Error $ctx 404 "Không tìm thấy chương $n." }
  if ($newN -ne $n -and (Test-Path -LiteralPath (Get-ChapterPath $dir $newN))) {
    return Send-Error $ctx 409 "Đã có chương $newN. Hãy xoá hoặc đổi số chương $newN trước."
  }
  $storyTitle = (Read-Meta $Root $slug).title
  Invoke-Mutation $ctx $slug ([bool]$body.push) {
    $c = Read-Chapter $src
    Write-Chapter $dir $newN $title $c.publishedAt $c.paras
    if ($newN -ne $n) { Remove-Item -LiteralPath $src }
    [void](Build-Bundle $Root)
    $what = if ($newN -ne $n) { "chương $n → chương $newN" } else { "chương $n" }
    @{ message = "Đã lưu $what`: $title"; n = $newN; commit = "Sửa $what`: $storyTitle" }
  }
}

function Invoke-DeleteChapter($ctx) {
  $body = Read-JsonBody $ctx
  $slug = "$($body.slug)"
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  try { $n = ConvertTo-ChapterNumber $body.n } catch { return Send-Error $ctx 400 $_.Exception.Message }
  $file = Get-ChapterPath (Get-StoryDir $Root $slug) $n
  if (-not (Test-Path -LiteralPath $file)) { return Send-Error $ctx 404 "Không tìm thấy chương $n." }
  $storyTitle = (Read-Meta $Root $slug).title
  Invoke-Mutation $ctx $slug ([bool]$body.push) {
    Remove-Item -LiteralPath $file
    [void](Build-Bundle $Root)
    @{ message = "Đã xoá chương $n."; commit = "Xoá chương $n`: $storyTitle" }
  }
}

# ---------- API: đăng chương từ .docx ----------
function Invoke-Preview($ctx) {
  $name = Get-SafeDocxName (Get-Query $ctx.Request 'name')
  if (-not $name) { return Send-Error $ctx 400 'Chỉ nhận file .docx' }
  if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory $TmpDir | Out-Null }
  $token = [guid]::NewGuid().ToString('N')
  $tmp = Join-Path $TmpDir "$token.docx"
  $fs = [IO.File]::Create($tmp)
  try { $ctx.Request.InputStream.CopyTo($fs) } finally { $fs.Close() }
  try {
    $chapters = @(foreach ($c in (Get-DocxChapters $tmp)) {
      $first = if ($c.paras.Count) { [string]$c.paras[0] } else { '' }
      if ($first.Length -gt 140) { $first = $first.Substring(0, 140) + '…' }
      [ordered]@{ n = $c.n; title = $c.title; paras = $c.paras.Count; words = (Get-WordCount $c.paras); first = $first }
    })
  } catch {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return Send-Error $ctx 400 "Không đọc được file $name (có phải file Word .docx hợp lệ?): $($_.Exception.Message)"
  }
  Send-Obj $ctx 200 ([ordered]@{ ok = $true; token = $token; name = $name; chapters = $chapters })
}

function Invoke-Publish($ctx) {
  $body = Read-JsonBody $ctx
  $slug = "$($body.slug)"
  if (-not (Test-StoryExists $slug)) { return Send-Error $ctx 404 "Không tìm thấy truyện: $slug" }
  $files = @($body.files)
  if ($files.Count -eq 0) { return Send-Error $ctx 400 'Chưa chọn file nào' }
  foreach ($f in $files) {
    if ("$($f.token)" -notmatch '^[a-f0-9]{32}$' -or -not (Get-SafeDocxName $f.name)) { return Send-Error $ctx 400 'Dữ liệu file không hợp lệ' }
    if (-not (Test-Path -LiteralPath (Join-Path $TmpDir "$($f.token).docx"))) { return Send-Error $ctx 400 "File tạm của $($f.name) đã hết hạn, hãy chọn lại file." }
  }

  Invoke-Mutation $ctx $slug ([bool]$body.push) {
    $meta = Read-Meta $Root $slug
    if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory $RawDir | Out-Null }
    $created = @(); $replaced = @{}
    $imported = New-Object Collections.ArrayList
    try {
      foreach ($f in $files) {
        $name = Get-SafeDocxName $f.name
        $dest = Join-Path $RawDir $name
        if (Test-Path -LiteralPath $dest) { Copy-Item -LiteralPath $dest "$dest.bak" -Force; $replaced[$dest] = "$dest.bak" } else { $created += $dest }
        Move-Item -LiteralPath (Join-Path $TmpDir "$($f.token).docx") $dest -Force
        $imported.AddRange((Import-DocxIntoStory $Root $slug $dest (Get-Today)))
        if (@($meta.sourceFiles) -notcontains $name) { Set-MetaProp $meta 'sourceFiles' (@(@($meta.sourceFiles) | Where-Object { $_ }) + $name) }
      }
      if ($body.touchDate) { Set-MetaProp $meta 'updatedAt' (Get-Today) }
      Write-Meta $Root $slug $meta
      [void](Build-Bundle $Root)
    } catch {
      $created | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
      $replaced.GetEnumerator() | ForEach-Object { Move-Item -LiteralPath $_.Value $_.Key -Force }
      throw
    }
    $replaced.Values | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }

    $uniq = @($imported | Sort-Object -Unique)
    $all = @(Get-ChapterNumbers (Get-StoryDir $Root $slug))
    $range = if ($uniq.Count -eq 1) { "chương $($uniq[0])" } else { "chương $($uniq[0])-$($uniq[-1])" }
    @{
      message = "Đã đăng $($uniq.Count) chương ($range). Truyện hiện có $($all.Count) chương."
      total = $all.Count; last = $(if ($all.Count) { $all[-1] } else { 0 }); first = $uniq[0]
      commit = "Đăng $range`: $($meta.title)"
    }
  }
}

function Invoke-Push($ctx) {
  Send-Obj $ctx 200 (Publish-ToGit "Cập nhật truyện ($((Get-Date).ToString('yyyy-MM-dd HH:mm')))")
}

# ---------- Static files ----------
function Send-Static($ctx, [string]$path) {
  $rel = $path.TrimStart('/').Replace('/', '\')
  if (-not $rel) { $rel = 'index.html' }
  $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
  if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { return Send-Error $ctx 403 'Forbidden' }
  if (Test-Path -LiteralPath $full -PathType Container) { $full = Join-Path $full 'index.html' }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    return Send-Bytes $ctx 404 'text/html; charset=utf-8' $Utf8NoBom.GetBytes('<h1>404</h1><p>Không tìm thấy trang. <a href="/">Về trang chủ</a></p>')
  }
  $ext = [IO.Path]::GetExtension($full).ToLower()
  $type = if ($Mime.ContainsKey($ext)) { $Mime[$ext] } else { 'application/octet-stream' }
  Send-Bytes $ctx 200 $type ([IO.File]::ReadAllBytes($full))
}

$Routes = @{
  'GET /api/ping'            = { param($c) Send-Obj $c 200 @{ ok = $true } }
  'GET /api/stories'         = { param($c) Invoke-ListStories $c }
  'GET /api/story'           = { param($c) Invoke-GetStory $c }
  'POST /api/story/save'     = { param($c) Invoke-SaveStory $c }
  'POST /api/story/cover'    = { param($c) Invoke-SaveCover $c }
  'POST /api/story/delete'   = { param($c) Invoke-DeleteStory $c }
  'POST /api/chapter/update' = { param($c) Invoke-UpdateChapter $c }
  'POST /api/chapter/delete' = { param($c) Invoke-DeleteChapter $c }
  'POST /api/preview'        = { param($c) Invoke-Preview $c }
  'POST /api/publish'        = { param($c) Invoke-Publish $c }
  'POST /api/push'           = { param($c) Invoke-Push $c }
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
    $route = $Routes["$($req.HttpMethod) $path"]
    if (-not $route) { return Send-Error $ctx 404 'API không tồn tại' }
    return & $route $ctx
  }
  if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'HEAD') { return Send-Error $ctx 405 'Method not allowed' }
  Send-Static $ctx $path
}

# ---------- Main loop ----------
if (Test-Path $TmpDir) { Get-ChildItem $TmpDir | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }  # dọn file tạm cũ
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Website:             http://localhost:$Port/"
Write-Host "Đăng & quản lý:      http://localhost:$Port/dang-truyen.html"
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
