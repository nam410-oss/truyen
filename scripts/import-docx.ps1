# Công cụ dòng lệnh cho nội dung truyện (logic nằm trong scripts/content-lib.ps1).
#
#   powershell -ExecutionPolicy Bypass -File scripts\import-docx.ps1
#       -> chỉ sinh lại data/stories.js từ content/ (an toàn, không đổi chương nào).
#
#   ... import-docx.ps1 -Slug <slug> -File <duong-dan.docx>
#       -> nhập các chương trong 1 file .docx vào truyện (ghi/ghi đè đúng các chương đó), rồi sinh lại bundle.
#
#   ... import-docx.ps1 -PreviewFile <duong-dan.docx>
#       -> chỉ in danh sách chương tìm thấy (JSON), không ghi gì.
#
#   ... import-docx.ps1 -RebuildFromDocx [-Slug <slug>]
#       -> XOÁ toàn bộ chuong-*.md rồi tạo lại từ "sourceFiles" trong meta.json (theo thứ tự).
#          Mọi chỉnh sửa chương (xoá/đổi tên/đổi số) làm trên web sẽ MẤT. Chỉ dùng khi cần khôi phục.
#
# LƯU Ý: file này phải lưu dạng UTF-8 có BOM (Windows PowerShell 5.1).

param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$PreviewFile,
  [string]$Slug,
  [string]$File,
  [switch]$RebuildFromDocx
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'content-lib.ps1')

function Find-Source([string]$name) {
  foreach ($dir in @((Join-Path $Root 'raw'), $Root)) {
    $f = Join-Path $dir $name
    if (Test-Path -LiteralPath $f) { return $f }
  }
  throw "Khong tim thay file nguon: $name"
}

if ($PreviewFile) {
  $summary = @(foreach ($c in (Get-DocxChapters $PreviewFile)) {
    $first = if ($c.paras.Count) { [string]$c.paras[0] } else { '' }
    if ($first.Length -gt 140) { $first = $first.Substring(0, 140) + '…' }
    [ordered]@{ n = $c.n; title = $c.title; paras = $c.paras.Count; words = (Get-WordCount $c.paras); first = $first }
  })
  if ($summary.Count) { ConvertTo-Json -InputObject $summary -Depth 3 -Compress } else { '[]' }
  return
}

if ($Slug -and $File) {
  $meta = Read-Meta $Root $Slug
  $nums = Import-DocxIntoStory $Root $Slug (Resolve-Path -LiteralPath $File).Path (Get-Date).ToString('yyyy-MM-dd')
  Write-Host "Da nhap $($nums.Count) chuong vao '$Slug': $(($nums | Sort-Object) -join ', ')"
}

if ($RebuildFromDocx) {
  foreach ($metaFile in Get-ChildItem (Join-Path $Root 'content\truyen\*\meta.json')) {
    $s = Split-Path -Leaf $metaFile.DirectoryName
    if ($Slug -and $s -ne $Slug) { continue }
    $meta = Read-Meta $Root $s
    $dir = $metaFile.DirectoryName
    Get-ChildItem -LiteralPath $dir -Filter 'chuong-*.md' | Remove-Item
    $seen = @{}
    foreach ($src in @($meta.sourceFiles)) {
      foreach ($n in (Import-DocxIntoStory $Root $s (Find-Source $src) $meta.updatedAt)) {
        if ($seen.ContainsKey($n)) { Write-Warning "Chuong $n bi trung (file $src) - ghi de" }
        $seen[$n] = 1
      }
    }
    $nums = @($seen.Keys | Sort-Object)
    for ($i = 1; $i -le $nums[-1]; $i++) { if (-not $seen.ContainsKey($i)) { Write-Warning "Thieu chuong $i" } }
    Write-Host "== $s : $($nums.Count) chuong"
  }
}

$count = Build-Bundle $Root
Write-Host "Da ghi data/stories.js ($count truyen)"
