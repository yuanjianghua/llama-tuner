# lib/gguf.ps1 - GGUF header parsing + layout analysis. Only reads the file: no logging,
# no other module may be required (enforced by tests/arch.ps1, deps=[]). ASCII-only.
# Format facts learned the hard way:
#   - v3: string lengths, tensor/kv counts, offsets are u64
#   - NEWER v3 files: tensor dims are u64 (older files u32) -> dual-hypothesis read
#   - tensor byte sizes are inferred from sorted offsets (dtype block math not needed)

function Read-GgufStr($br) {
  $len = [int]$br.ReadUInt64()
  return [Text.Encoding]::UTF8.GetString($br.ReadBytes($len))
}

function Read-GgufValue($br, [int]$type, [int]$depth) {
  switch ($type) {
    0 { return $br.ReadByte() }
    1 { return $br.ReadSByte() }
    2 { return $br.ReadUInt16() }
    3 { return $br.ReadInt16() }
    4 { return $br.ReadUInt32() }
    5 { return $br.ReadInt32() }
    6 { return $br.ReadSingle() }
    7 { return ($br.ReadByte() -ne 0) }
    8 { return (Read-GgufStr $br) }
    9 {
      $elemType = $br.ReadInt32(); $count = [int]$br.ReadUInt64()
      $arr = @(); $cap = [Math]::Min($count, 64)
      for ($i = 0; $i -lt $count; $i++) {
        $v = Read-GgufValue $br $elemType ($depth + 1)
        if ($i -lt $cap) { $arr += $v }
      }
      return $arr
    }
    10 { return $br.ReadUInt64() }
    11 { return $br.ReadInt64() }
    12 { return $br.ReadDouble() }
    default { throw "gguf: unsupported value type $type" }
  }
}

function Parse-GgufHeader([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $br = New-Object IO.BinaryReader($fs)
    $magic = [Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
    if ($magic -ne 'GGUF') { throw "not a GGUF file: $path" }
    $version = $br.ReadInt32()
    $nTensors = $br.ReadUInt64()
    $nKv = [int]$br.ReadUInt64()
    $meta = @{}
    for ($i = 0; $i -lt $nKv; $i++) {
      $key = Read-GgufStr $br
      $type = $br.ReadInt32()
      $val = Read-GgufValue $br $type 0
      if (-not $meta.ContainsKey($key)) { $meta[$key] = $val }
    }
    $tensors = New-Object System.Collections.Generic.List[object]
    # tensor info: n_dims u32, dims u32[] or u64[], dtype u32, offset u64.
    # Try 64-bit dims first; on implausible entry, rewind and retry with 32-bit dims.
    $tensorStart = $fs.Position
    foreach ($dimBits in @(64, 32)) {
      [void]$fs.Seek($tensorStart, 'Begin')
      $ok = $true
      $tensors.Clear()
      try {
        for ($i = 0; $i -lt $nTensors; $i++) {
          $name = Read-GgufStr $br
          if ($name.Length -lt 1 -or $name.Length -gt 200) { $ok = $false; break }
          $nDims = [int]$br.ReadUInt32()
          if ($nDims -lt 1 -or $nDims -gt 4) { $ok = $false; break }
          for ($d = 0; $d -lt $nDims; $d++) {
            $dim = if ($dimBits -eq 64) { $br.ReadUInt64() } else { [uint64]$br.ReadUInt32() }
            if ($dim -gt 1000000000) { $ok = $false; break }
          }
          if (-not $ok) { break }
          [void]$br.ReadUInt32()               # dtype (sizes inferred from offsets instead)
          $off = $br.ReadUInt64()
          $tensors.Add([pscustomobject]@{ Name = $name; Offset = $off })  # pscustomobject: Sort-Object cannot resolve hashtable properties
        }
      } catch { $ok = $false }
      if ($ok -and $tensors.Count -eq $nTensors) { break }
    }
    if ($tensors.Count -ne $nTensors) { throw 'gguf: cannot parse tensor info (tried 64-bit and 32-bit dims)' }
    return @{ Version = $version; Tensors = $tensors; Meta = $meta }
  } finally { $fs.Dispose() }
}

# Turns a parsed header into the numbers the planner needs. Throws on inconsistent accounting.
function Get-GgufLayout($hdr, [double]$modelBytes) {
  $arch = [string]$hdr.Meta['general.architecture']
  $nLayers = [int]$hdr.Meta["$arch.block_count"]
  if (-not $nLayers) { $nLayers = [int]$hdr.Meta['llama.block_count'] }
  if (-not $nLayers) { throw "cannot find block_count for arch '$arch'" }
  $kvh = [int]$hdr.Meta["$arch.attention.head_count_kv"]; if (-not $kvh) { $kvh = 4 }
  $heads = [int]$hdr.Meta["$arch.attention.head_count"]; if (-not $heads) { $heads = 32 }
  $embd = [int]$hdr.Meta["$arch.embedding_length"]; if (-not $embd) { $embd = 4096 }
  $hd = [int]$hdr.Meta["$arch.attention.key_length"]
  if (-not $hd) { $hd = [Math]::Floor($embd / $heads) }
  $faInt = [int]$hdr.Meta["$arch.full_attention_interval"]; if (-not $faInt -or $faInt -lt 1) { $faInt = 1 }
  $kvLayers = [int][Math]::Ceiling($nLayers / $faInt)

  $ts = @($hdr.Tensors | Sort-Object Offset)
  $expertBytes = [double]0; $nonExpertBytes = [double]0
  $perLayerExpert = @{}
  for ($i = 0; $i -lt $ts.Count; $i++) {
    $size = if ($i -lt $ts.Count - 1) { $ts[$i + 1].Offset - $ts[$i].Offset } else { 0 }
    $m = [regex]::Match($ts[$i].Name, 'blk\.(\d+)\.')
    if ($ts[$i].Name -match '_exps\.') {
      $expertBytes += $size
      if ($m.Success) {
        $L = [int]$m.Groups[1].Value
        if (-not $perLayerExpert.ContainsKey($L)) { $perLayerExpert[$L] = [double]0 }
        $perLayerExpert[$L] += $size
      }
    } else { $nonExpertBytes += $size }
  }
  $isMoE = ($expertBytes -gt 0 -and $perLayerExpert.Count -gt 0)
  if ($expertBytes -lt 0 -or $nonExpertBytes -lt 0 -or ($expertBytes + $nonExpertBytes) -gt $modelBytes * 2) {
    throw 'gguf: tensor size accounting failed (offset sort/parse issue)'
  }
  $perLayerExpertMB = if ($isMoE) { $expertBytes / $nLayers / 1MB } else { $modelBytes / $nLayers / 1MB }
  return [pscustomobject]@{
    Arch = $arch; NLayers = $nLayers; KvLayers = $kvLayers; KvHeads = $kvh; HeadDim = $hd; FaInt = $faInt
    IsMoE = $isMoE; ExpertBytes = $expertBytes; NonExpertBytes = $nonExpertBytes; PerLayerExpertMB = $perLayerExpertMB
  }
}
