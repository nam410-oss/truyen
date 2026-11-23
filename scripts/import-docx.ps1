# Import .docx -> chapter Markdown files + data/stories.js bundle for the static demo.
#
# Usage (from project root):  powershell -ExecutionPolicy Bypass -File scripts\import-docx.ps1
#
# For every content/truyen/<slug>/meta.json, reads the files listed in "sourceFiles"
# (looked up in raw/ first, then the project root), splits them on "Chuong NN: Title"
# headings and writes content/truyen/<slug>/chuong-XXX.md. Idempotent: old chuong-*.md
# files are removed before writing. Finally writes data/stories.js (window.STORIES)
# which index.html / truyen.html / doc.html load.
#
# Preview mode (used by scripts/server.ps1 / dang-chuong.html): only lists the chapters
# found in ONE .docx as JSON, writes nothing:
#   powershell -File scripts\import-docx.ps1 -PreviewFile path\to\file.docx
#
# NOTE: this file MUST be saved as UTF-8 *with BOM* - Windows PowerShell 5.1 reads
# BOM-less scripts as ANSI and the Vietnamese heading regex would silently stop matching.

param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$PreviewFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$utf8 = New-Object System.Text.UTF8Encoding($false)
$W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
# "Chuong 01: Title"  (U+01B0 = u-horn, U+01A1 = o-horn, U+FF1A = full-width colon)
$headingRe = '^\s*Chương\s+(\d+)\s*[:：\-–]\s*(.+?)\s*$'

function Read-DocxParagraphs([string]$path) {
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $reader = New-Object IO.StreamReader($zip.GetEntry('word/document.xml').Open(), [Text.Encoding]::UTF8)
    [xml]$xml = $reader.ReadToEnd()
    $reader.Close()
  } finally { $zip.Dispose() }
  $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace('w', $W)
  foreach ($p in $xml.SelectNodes('//w:body//w:p', $ns)) {
    $sb = New-Object Text.StringBuilder
    foreach ($n in $p.SelectNodes('.//w:t | .//w:tab | .//w:br', $ns)) {
      switch ($n.LocalName) { 't' { [void]$sb.Append($n.InnerText) } default { [void]$sb.Append(' ') } }
    }
    $text = ($sb.ToString() -replace '[\s ]+', ' ').Trim()
    if ($text) { $text }
  }
}

function Find-Source([string]$name) {
  foreach ($dir in @((Join-Path $Root 'raw'), $Root)) {
    $f = Join-Path $dir $name
    if (Test-Path -LiteralPath $f) { return $f }
  }
  throw "Khong tim thay file nguon: $name"
}

if ($PreviewFile) {
  $list = New-Object Collections.ArrayList
  $current = $null
  foreach ($para in Read-DocxParagraphs $PreviewFile) {
    if ($para -match $headingRe) {
      $current = [ordered]@{ n = [int]$Matches[1]; title = $Matches[2]; paras = 0; words = 0; first = '' }
      [void]$list.Add($current)
    } elseif ($current) {
      $current['paras'] += 1
      $current['words'] += ($para -split '\s+').Count
      if (-not $current['first']) { $current['first'] = if ($para.Length -gt 140) { $para.Substring(0, 140) + '…' } else { $para } }
    }
  }
  ConvertTo-Json -InputObject @($list) -Depth 3 -Compress
  return
}

$bundle = @()
foreach ($metaFile in Get-ChildItem (Join-Path $Root 'content\truyen\*\meta.json')) {
  $dir = $metaFile.DirectoryName
  $meta = [IO.File]::ReadAllText($metaFile.FullName, $utf8) | ConvertFrom-Json
  Write-Host "== $($meta.slug)"

  $chapters = @{}
  foreach ($src in $meta.sourceFiles) {
    $current = $null
    foreach ($para in Read-DocxParagraphs (Find-Source $src)) {
      if ($para -match $headingRe) {
        $num = [int]$Matches[1]
        if ($chapters.ContainsKey($num)) { Write-Warning "Chuong $num bi trung (file $src) - ghi de" }
        $current = [ordered]@{ n = $num; title = $Matches[2]; paras = New-Object Collections.ArrayList }
        $chapters[$num] = $current
      } elseif ($current) {
        [void]$current.paras.Add($para)
      }  # text before the first heading (file title, "(Chuong 01 - 10)") is skipped
    }
  }

  $nums = $chapters.Keys | Sort-Object
  if (-not $nums) { Write-Warning 'Khong tim thay chuong nao'; continue }
  for ($i = 1; $i -le $nums[-1]; $i++) { if (-not $chapters.ContainsKey($i)) { Write-Warning "Thieu chuong $i" } }

  Get-ChildItem (Join-Path $dir 'chuong-*.md') -ErrorAction SilentlyContinue | Remove-Item
  foreach ($n in $nums) {
    $c = $chapters[$n]
    $title = $c.title -replace '"', '\"'
    $md = "---`nnumber: $n`ntitle: `"$title`"`npublishedAt: `"$($meta.updatedAt)`"`n---`n`n" + (($c.paras) -join "`n`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $dir ('chuong-{0:D3}.md' -f $n)), $md, $utf8)
  }
  Write-Host "   $($nums.Count) chuong (1 -> $($nums[-1]))"

  $story = [ordered]@{}
  foreach ($prop in $meta.PSObject.Properties) { if ($prop.Name -ne 'sourceFiles') { $story[$prop.Name] = $prop.Value } }
  $story.chapters = @($nums | ForEach-Object { $c = $chapters[$_]; [ordered]@{ n = $c.n; title = $c.title; paras = @($c.paras) } })
  $bundle += $story
}

$dataDir = Join-Path $Root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }
$json = ConvertTo-Json -InputObject @($bundle) -Depth 8 -Compress
[IO.File]::WriteAllText((Join-Path $dataDir 'stories.js'), "// Tu dong tao boi scripts/import-docx.ps1 - khong sua tay.`nwindow.STORIES = $json;`n", $utf8)
Write-Host "Da ghi data/stories.js"
