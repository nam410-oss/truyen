# Thư viện dùng chung cho import-docx.ps1 và server.ps1 (nạp bằng: . "$PSScriptRoot\content-lib.ps1").
#
# Nguồn dữ liệu chuẩn là các file content/truyen/<slug>/chuong-NNN.md + meta.json.
# File .docx chỉ là đầu vào: nhập một file .docx sẽ GHI/GHI ĐÈ các chương có trong file đó,
# không xoá chương khác — nên các chỉnh sửa (xoá, đổi tên, đổi số chương) được giữ nguyên.
#
# LƯU Ý: file này phải lưu dạng UTF-8 có BOM (Windows PowerShell 5.1).

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$HeadingRe = '^\s*Chương\s+(\d+)\s*[:：\-–]\s*(.+?)\s*$'
$SlugRe = '^[a-z0-9]+(-[a-z0-9]+)*$'
$WordNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'

# ---------- JSON ----------
function ConvertTo-JsonString([string]$s) {
  '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t') + '"'
}

# JSON dễ đọc cho meta.json (ConvertTo-Json của PS 5.1 thụt lề rất xấu).
function ConvertTo-PrettyJson($v, [string]$indent = '') {
  $next = $indent + '  '
  if ($null -eq $v) { return 'null' }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [string]) { return ConvertTo-JsonString $v }
  if ($v -is [ValueType]) { return [string]$v }
  if ($v -is [Collections.IDictionary]) {
    $props = @($v.Keys | ForEach-Object { (ConvertTo-JsonString $_) + ': ' + (ConvertTo-PrettyJson $v[$_] $next) })
    if ($props.Count -eq 0) { return '{}' }
    return "{`n$next" + ($props -join ",`n$next") + "`n$indent}"
  }
  if ($v -is [Collections.IList]) {
    $items = @($v | ForEach-Object { ConvertTo-PrettyJson $_ $next })
    if ($items.Count -eq 0) { return '[]' }
    $oneLine = '[' + ($items -join ', ') + ']'
    if ($oneLine.Length -le 70) { return $oneLine }
    return "[`n$next" + ($items -join ",`n$next") + "`n$indent]"
  }
  $props = @($v.PSObject.Properties | ForEach-Object { (ConvertTo-JsonString $_.Name) + ': ' + (ConvertTo-PrettyJson $_.Value $next) })
  if ($props.Count -eq 0) { return '{}' }
  return "{`n$next" + ($props -join ",`n$next") + "`n$indent}"
}

# ---------- Đọc .docx ----------
function Read-DocxParagraphs([string]$path) {
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $entry = $zip.GetEntry('word/document.xml')
    if (-not $entry) { throw 'File không có word/document.xml (không phải file Word .docx).' }
    $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
    [xml]$xml = $reader.ReadToEnd()
    $reader.Close()
  } finally { $zip.Dispose() }
  $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace('w', $WordNs)
  foreach ($p in $xml.SelectNodes('//w:body//w:p', $ns)) {
    $sb = New-Object Text.StringBuilder
    foreach ($n in $p.SelectNodes('.//w:t | .//w:tab | .//w:br', $ns)) {
      if ($n.LocalName -eq 't') { [void]$sb.Append($n.InnerText) } else { [void]$sb.Append(' ') }
    }
    $text = ($sb.ToString() -replace '[\s ]+', ' ').Trim()
    if ($text) { $text }
  }
}

# Tách .docx thành chương theo dòng "Chương NN: Tên". Phần trước chương đầu tiên bị bỏ qua.
function Get-DocxChapters([string]$path) {
  $list = New-Object Collections.ArrayList
  $current = $null
  foreach ($para in Read-DocxParagraphs $path) {
    if ($para -match $HeadingRe) {
      $current = [ordered]@{ n = [int]$Matches[1]; title = $Matches[2]; paras = (New-Object Collections.ArrayList) }
      [void]$list.Add($current)
    } elseif ($current) {
      [void]$current.paras.Add($para)
    }
  }
  return , $list
}

function Get-WordCount($paras) {
  $all = (@($paras) -join ' ').Trim()
  if (-not $all) { return 0 }
  return ($all -split '\s+').Count
}

# ---------- Truyện & chương ----------
function Get-StoryDir([string]$Root, [string]$slug) {
  if ($slug -notmatch $SlugRe) { throw "Đường dẫn truyện (slug) không hợp lệ: $slug" }
  return Join-Path $Root "content\truyen\$slug"
}

function Read-Meta([string]$Root, [string]$slug) {
  $p = Join-Path (Get-StoryDir $Root $slug) 'meta.json'
  if (-not (Test-Path -LiteralPath $p)) { throw "Không tìm thấy truyện: $slug" }
  return [IO.File]::ReadAllText($p, $Utf8NoBom) | ConvertFrom-Json
}

function Write-Meta([string]$Root, [string]$slug, $meta) {
  $p = Join-Path (Get-StoryDir $Root $slug) 'meta.json'
  [IO.File]::WriteAllText($p, (ConvertTo-PrettyJson $meta) + "`n", $Utf8NoBom)
}

# Cập nhật tại chỗ để giữ thứ tự các trường trong meta.json (Add-Member -Force sẽ đẩy trường xuống cuối).
function Set-MetaProp($meta, [string]$name, $value) {
  if ($meta.PSObject.Properties[$name]) { $meta.$name = $value }
  else { $meta | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Get-CoverUrl([string]$Root, [string]$slug, $meta) {
  if (-not $meta.cover) { return '' }
  $f = Join-Path (Get-StoryDir $Root $slug) $meta.cover
  if (-not (Test-Path -LiteralPath $f)) { return '' }
  return "content/truyen/$slug/$($meta.cover)?v=$((Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks)"
}

function Get-ChapterPath([string]$dir, [int]$n) { Join-Path $dir ('chuong-{0:D3}.md' -f $n) }

function Get-ChapterNumbers([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return }
  Get-ChildItem -LiteralPath $dir -Filter 'chuong-*.md' | ForEach-Object { [int]($_.BaseName -replace '\D', '') } | Sort-Object
}

function Read-Chapter([string]$file) {
  $text = [IO.File]::ReadAllText($file, $Utf8NoBom) -replace "`r`n", "`n"
  $n = [int]([IO.Path]::GetFileNameWithoutExtension($file) -replace '\D', '')
  $title = ''; $pub = ''; $body = $text
  if ($text -match '(?s)^---\n(.*?)\n---\n?(.*)$') {
    $fm = $Matches[1]; $body = $Matches[2]
    foreach ($line in $fm -split "`n") {
      if ($line -match '^title:\s*"(.*)"\s*$') { $title = $Matches[1] -replace '\\"', '"' -replace '\\\\', '\' }
      elseif ($line -match '^publishedAt:\s*"?([^"]*)"?\s*$') { $pub = $Matches[1] }
    }
  }
  $paras = @($body -split '\n\s*\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  return [ordered]@{ n = $n; title = $title; publishedAt = $pub; paras = $paras }
}

function Write-Chapter([string]$dir, [int]$n, [string]$title, [string]$publishedAt, $paras) {
  $t = $title -replace '\\', '\\' -replace '"', '\"'
  $md = "---`nnumber: $n`ntitle: `"$t`"`npublishedAt: `"$publishedAt`"`n---`n`n" + (@($paras) -join "`n`n") + "`n"
  [IO.File]::WriteAllText((Get-ChapterPath $dir $n), $md, $Utf8NoBom)
}

# Nhập 1 file .docx vào truyện: ghi (hoặc ghi đè) các chương có trong file. Trả về danh sách số chương.
function Import-DocxIntoStory([string]$Root, [string]$slug, [string]$docx, [string]$publishedAt) {
  $dir = Get-StoryDir $Root $slug
  $chapters = Get-DocxChapters $docx
  if ($chapters.Count -eq 0) { throw "File $(Split-Path -Leaf $docx) không có dòng nào dạng 'Chương NN: Tên chương'." }
  $nums = New-Object Collections.ArrayList
  foreach ($c in $chapters) {
    Write-Chapter $dir $c.n $c.title $publishedAt $c.paras
    [void]$nums.Add($c.n)
  }
  return , $nums
}

# Sinh lại data/stories.js (window.STORIES) từ toàn bộ meta.json + chuong-*.md.
function Build-Bundle([string]$Root) {
  $bundle = New-Object Collections.ArrayList
  foreach ($metaFile in @(Get-ChildItem (Join-Path $Root 'content\truyen\*\meta.json') -ErrorAction SilentlyContinue)) {
    $dir = $metaFile.DirectoryName
    $slug = Split-Path -Leaf $dir
    $meta = [IO.File]::ReadAllText($metaFile.FullName, $Utf8NoBom) | ConvertFrom-Json
    $story = [ordered]@{}
    foreach ($p in $meta.PSObject.Properties) { if ($p.Name -notin 'sourceFiles', 'cover') { $story[$p.Name] = $p.Value } }
    $story.slug = $slug
    $cover = Get-CoverUrl $Root $slug $meta
    if ($cover) { $story.cover = $cover }
    $story.chapters = @(foreach ($n in @(Get-ChapterNumbers $dir)) {
      $c = Read-Chapter (Get-ChapterPath $dir $n)
      [ordered]@{ n = $c.n; title = $c.title; paras = @($c.paras) }
    })
    [void]$bundle.Add($story)
  }
  $dataDir = Join-Path $Root 'data'
  if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }
  $json = if ($bundle.Count) { ConvertTo-Json -InputObject @($bundle) -Depth 8 -Compress } else { '[]' }
  [IO.File]::WriteAllText((Join-Path $dataDir 'stories.js'), "// Tu dong tao boi scripts/content-lib.ps1 - khong sua tay.`nwindow.STORIES = $json;`n", $Utf8NoBom)
  return $bundle.Count
}
