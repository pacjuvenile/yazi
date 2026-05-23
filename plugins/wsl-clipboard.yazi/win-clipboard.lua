local helper = require(".helper")
local process = require(".process")
local ps = require(".ps")
local util = require(".util")

local M = {}

local OWNER_FORMAT = "wsl-clipboard.yazi.owner"
local OWNER_MARKER = "wsl-clipboard.yazi"

local function clipboard_data_object_retry()
	return {
		"function Get-ClipboardDataObjectWithRetry {",
		"  $last = $null",
		"  for ($i = 0; $i -lt 30; $i++) {",
		"    try { return [System.Windows.Forms.Clipboard]::GetDataObject() }",
		"    catch { $last = $_; Start-Sleep -Milliseconds 100 }",
		"  }",
		"  if ($last) { throw ('Failed to read Windows clipboard after retries: ' + $last.Exception.Message) }",
		"  return $null",
		"}",
	}
end

local function append_lines(target, source)
	for _, line in ipairs(source or {}) do
		target[#target + 1] = line
	end
end

local function describe_probe_error(helper_err, fallback_err)
	local parts = {}
	local fallback = util.trim(fallback_err or "")
	local helper_msg = util.trim(helper_err or "")
	if fallback ~= "" then
		parts[#parts + 1] = "PowerShell fallback: " .. fallback
	end
	if helper_msg ~= "" then
		parts[#parts + 1] = "helper: " .. helper_msg
	end
	if #parts == 0 then
		return "unknown clipboard access error"
	end
	return table.concat(parts, "; ")
end

local function parse_paste_output(out)
	if not out or out == "" then
		return nil
	end

	local first = out:match("^([^\n]+)")
	local kind = first and first:match("^__kind__:(.+)$")
	if kind == "files" then
		local effect = out:match("\n__effect__:(.-)\n")
		local owner = out:match("\n__owner__:(.-)\n") == OWNER_MARKER
		local files = {}
		local body = out:gsub("^__kind__:files\n", "", 1):gsub("^__effect__:[^\n]*\n", "", 1)
		body = body:gsub("^__owner__:[^\n]*\n", "", 1)
		for line in body:gmatch("[^\n]+") do
			files[#files + 1] = line
		end
		return #files > 0 and "files" or nil, files, nil, effect == "move" and "move" or "copy", owner
	elseif kind == "html" then
		return "html", true
	elseif kind == "image" then
		local ext = out:match("\n([^%s]+)%s*$")
		return ext and ext ~= "" and "image" or nil, ext
	elseif kind == "text" then
		return "text", true
	end

	return nil
end

function M.write_files(paths, cut)
	if #paths == 0 then
		return true
	end

	local helper_ok, helper_err = helper.write_files(paths, cut == true)
	if helper_ok then
		return true
	end
	return false, helper_err
end

function M.clear()
	local helper_ok, helper_err = helper.clear()
	if helper_ok then
		return true
	end
	return false, helper_err
end

function M.clear_owned(paths, cut)
	local helper_ok, helper_err = helper.clear_owned(paths, cut == true)
	if helper_ok then
		return true
	end
	return false, helper_err
end

function M.read_paste()
	local helper_out, helper_err, helper_code = helper.read_paste()
	if helper_code == 0 then
		return parse_paste_output(helper_out)
	end
	util.debug_log("helper read_paste fallback: " .. tostring(helper_err))

	local script = ps.join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"Add-Type -AssemblyName System.Drawing",
	})
	local lines = {}
	append_lines(lines, clipboard_data_object_retry())
	append_lines(lines, {
		"$d = Get-ClipboardDataObjectWithRetry",
		"if (-not $d) { exit 0 }",
		"if ($d.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {",
		"  Write-Output '__kind__:files'",
		"  if ($d.GetDataPresent('Preferred DropEffect')) {",
		"    $v = $d.GetData('Preferred DropEffect')",
		"    if ($v -is [System.IO.MemoryStream]) {",
		"      $v.Position = 0; $b = New-Object byte[] 4; $null = $v.Read($b, 0, 4); $effect = [BitConverter]::ToInt32($b, 0)",
		"    } elseif ($v -is [byte[]]) {",
		"      $effect = [BitConverter]::ToInt32($v, 0)",
		"    } else {",
		"      $effect = 1",
		"    }",
		"  } else {",
		"    $effect = 1",
		"  }",
		"  Write-Output ('__effect__:' + $(if ($effect -eq 2) { 'move' } else { 'copy' }))",
		"  if ($d.GetDataPresent('" .. OWNER_FORMAT .. "')) { Write-Output '__owner__:" .. OWNER_MARKER .. "' }",
		"  $d.GetFileDropList() | ForEach-Object { Write-Output $_ }",
		"  exit 0",
		"}",
		"if ($d.GetDataPresent('PNG'))  { Write-Output '__kind__:image'; Write-Output 'png'; exit 0 }",
		"if ($d.GetDataPresent('JFIF')) { Write-Output '__kind__:image'; Write-Output 'jpg'; exit 0 }",
		"if ($d.GetDataPresent('GIF'))  { Write-Output '__kind__:image'; Write-Output 'gif'; exit 0 }",
		"if ($d.GetDataPresent('TIFF')) { Write-Output '__kind__:image'; Write-Output 'tiff'; exit 0 }",
		"if ($d.GetDataPresent('DeviceIndependentBitmap') -or $d.GetDataPresent('Format17')) { Write-Output '__kind__:image'; Write-Output 'bmp'; exit 0 }",
		"$bitmap = $d.GetData([System.Windows.Forms.DataFormats]::Bitmap)",
		"if ($bitmap -is [System.Drawing.Image]) { Write-Output '__kind__:image'; Write-Output 'bmp'; exit 0 }",
		"try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { $img = $null }",
		"if ($img) { Write-Output '__kind__:image'; Write-Output 'png'; exit 0 }",
		"if ($d.GetDataPresent([System.Windows.Forms.DataFormats]::Html)) { Write-Output '__kind__:html'; exit 0 }",
		"if ($d.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText) -or $d.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) { Write-Output '__kind__:text'; exit 0 }",
	})

	script = script .. "; " .. ps.join(lines)
	local out, err, code = process.exec_ps(script, "10s")
	util.debug_log("read_paste code=" .. tostring(code) .. " out=" .. tostring(out) .. " err=" .. tostring(err))
	if code ~= 0 then
		return nil, nil, describe_probe_error(helper_err, err)
	end
	return parse_paste_output(out)
end

function M.probe_image()
	local helper_ext, helper_err, helper_code = helper.probe_image()
	if helper_code == 0 then
		helper_ext = util.trim(helper_ext or "")
		return helper_ext ~= "" and helper_ext:lower() or nil
	end
	util.debug_log("helper probe_image fallback: " .. tostring(helper_err))

	local script = ps.join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"Add-Type -AssemblyName System.Drawing",
	})
	local lines = {}
	append_lines(lines, clipboard_data_object_retry())
	append_lines(lines, {
		"$d = Get-ClipboardDataObjectWithRetry",
		"if (-not $d) { exit 0 }",
		"if ($d.GetDataPresent('PNG'))  { Write-Output 'png'; exit 0 }",
		"if ($d.GetDataPresent('JFIF')) { Write-Output 'jpg'; exit 0 }",
		"if ($d.GetDataPresent('GIF'))  { Write-Output 'gif'; exit 0 }",
		"if ($d.GetDataPresent('TIFF')) { Write-Output 'tiff'; exit 0 }",
		"if ($d.GetDataPresent('DeviceIndependentBitmap') -or $d.GetDataPresent('Format17')) { Write-Output 'bmp'; exit 0 }",
		"$bitmap = $d.GetData([System.Windows.Forms.DataFormats]::Bitmap)",
		"if ($bitmap -is [System.Drawing.Image]) { Write-Output 'bmp'; exit 0 }",
		"try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { $img = $null }",
		"if ($img) {",
		"  Write-Output 'png'",
		"}",
	})

	script = script .. "; " .. ps.join(lines)
	local out, err, code = process.exec_ps(script, "10s")
	if code ~= 0 then
		return nil, describe_probe_error(helper_err, err)
	end
	out = util.trim(out)
	return out ~= "" and out:lower() or nil
end

function M.save_html(dst)
	local script = ps.join({
		"Add-Type -AssemblyName System.Windows.Forms",
	})
	local lines = {}
	append_lines(lines, clipboard_data_object_retry())
	append_lines(lines, {
		"$d = Get-ClipboardDataObjectWithRetry",
		"if (-not $d) { throw 'No clipboard data object' }",
		"if (-not $d.GetDataPresent([System.Windows.Forms.DataFormats]::Html)) { throw 'No html in clipboard' }",
		"$raw = [string]$d.GetData([System.Windows.Forms.DataFormats]::Html)",
		"$m = [regex]::Match($raw, 'StartHTML:(\\d+).*?EndHTML:(\\d+)', [System.Text.RegularExpressions.RegexOptions]::Singleline)",
		"if ($m.Success) {",
		"  $start = [int]$m.Groups[1].Value; $end = [int]$m.Groups[2].Value",
		"  $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)",
		"  if ($start -ge 0 -and $end -gt $start -and $end -le $bytes.Length) { $raw = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $end - $start) }",
		"} elseif ($raw -match '(<html[\\s\\S]*</html>)') {",
		"  $raw = $Matches[1]",
		"}",
		"[System.IO.File]::WriteAllText('" .. ps.quote(dst) .. "', $raw, [System.Text.Encoding]::UTF8)",
	})

	script = script .. "; " .. ps.join(lines)
	local _, err, code = process.exec_ps(script, "10s")
	return code == 0, err
end

function M.save_image(dst)
	local ext = tostring(dst):match("%.([^.\\/:]+)$")
	if not ext then
		return false, "missing file extension"
	end

	local script = ps.join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"Add-Type -AssemblyName System.Drawing",
	})
	local lines = {}
	append_lines(lines, clipboard_data_object_retry())
	append_lines(lines, {
		"$d = Get-ClipboardDataObjectWithRetry",
		"if (-not $d) { throw 'No clipboard data object' }",
		"function Save-RawBytes($formatName, $path) {",
		"  if (-not $d.GetDataPresent($formatName)) { return $false }",
		"  $data = $d.GetData($formatName)",
		"  if ($data -is [System.IO.MemoryStream]) { [System.IO.File]::WriteAllBytes($path, $data.ToArray()); return $true }",
		"  if ($data -is [byte[]]) { [System.IO.File]::WriteAllBytes($path, $data); return $true }",
		"  return $false",
		"}",
		"function Get-ClipboardBytes($formatName) {",
		"  if (-not $d.GetDataPresent($formatName)) { return $null }",
		"  $data = $d.GetData($formatName)",
		"  if ($data -is [System.IO.MemoryStream]) { return $data.ToArray() }",
		"  if ($data -is [byte[]]) { return $data }",
		"  return $null",
		"}",
		"function Load-ImageFromBytes($bytes) {",
		"  if (-not $bytes -or $bytes.Length -eq 0) { return $null }",
		"  try {",
		"    $ms = New-Object System.IO.MemoryStream",
		"    $ms.Write($bytes, 0, $bytes.Length)",
		"    $ms.Position = 0",
		"    return [System.Drawing.Image]::FromStream($ms)",
		"  } catch { return $null }",
		"}",
		"function Get-ImageObject() {",
		"  try { $img = [System.Windows.Forms.Clipboard]::GetImage() } catch { $img = $null }",
		"  if ($img) { return $img }",
		"  $bitmap = $d.GetData([System.Windows.Forms.DataFormats]::Bitmap)",
		"  if ($bitmap -is [System.Drawing.Image]) { return $bitmap }",
		"  foreach ($name in @('PNG', 'JFIF', 'GIF', 'TIFF')) {",
		"    $img = Load-ImageFromBytes (Get-ClipboardBytes $name)",
		"    if ($img) { return $img }",
		"  }",
		"  return $null",
		"}",
		"function Save-ImageObject($obj, $path, $fmt) {",
		"  if ($obj -is [System.Drawing.Image]) { $obj.Save($path, $fmt); return $true }",
		"  return $false",
		"}",
		"function Save-DibAsBmp($formatName, $path) {",
		"  $dib = Get-ClipboardBytes $formatName",
		"  if (-not $dib -or $dib.Length -lt 40) { return $false }",
		"  $headerSize = [BitConverter]::ToInt32($dib, 0)",
		"  if ($headerSize -le 0 -or $headerSize -gt $dib.Length) { return $false }",
		"  $bitCount = [BitConverter]::ToUInt16($dib, 14)",
		"  $compression = if ($dib.Length -ge 20) { [BitConverter]::ToInt32($dib, 16) } else { 0 }",
		"  $clrUsed = if ($dib.Length -ge 36) { [BitConverter]::ToInt32($dib, 32) } else { 0 }",
		"  $paletteEntries = 0",
		"  if ($bitCount -le 8) { $paletteEntries = if ($clrUsed -gt 0) { $clrUsed } else { [int][Math]::Pow(2, $bitCount) } }",
		"  $extraMasks = 0",
		"  if ($headerSize -eq 40 -and ($compression -eq 3 -or $compression -eq 6)) { $extraMasks = if ($compression -eq 6) { 16 } else { 12 } }",
		"  $offBits = 14 + $headerSize + $extraMasks + (4 * $paletteEntries)",
		"  if ($offBits -gt 14 + $dib.Length) { $offBits = 14 + $headerSize }",
		"  $fileSize = 14 + $dib.Length",
		"  $bmp = New-Object byte[] $fileSize",
		"  $bmp[0] = 0x42; $bmp[1] = 0x4d",
		"  [BitConverter]::GetBytes([int]$fileSize).CopyTo($bmp, 2)",
		"  [BitConverter]::GetBytes([int]0).CopyTo($bmp, 6)",
		"  [BitConverter]::GetBytes([int]$offBits).CopyTo($bmp, 10)",
		"  [Array]::Copy($dib, 0, $bmp, 14, $dib.Length)",
		"  [System.IO.File]::WriteAllBytes($path, $bmp)",
		"  return $true",
		"}",
		"$dst = '" .. ps.quote(dst) .. "'",
		"$ext = '" .. ps.quote(ext:lower()) .. "'",
		"switch ($ext) {",
		"  'png'  { if (Save-RawBytes 'PNG' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Png }",
		"  'jpg'  { if (Save-RawBytes 'JFIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Jpeg }",
		"  'jpeg' { if (Save-RawBytes 'JFIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Jpeg }",
		"  'gif'  { if (Save-RawBytes 'GIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Gif }",
		"  'tif'  { if (Save-RawBytes 'TIFF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }",
		"  'tiff' { if (Save-RawBytes 'TIFF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }",
		"  'bmp'  {",
		"    $fmt = [System.Drawing.Imaging.ImageFormat]::Bmp",
		"    if (Save-ImageObject ($d.GetData([System.Windows.Forms.DataFormats]::Bitmap)) $dst $fmt) { exit 0 }",
		"    if (Save-DibAsBmp 'Format17' $dst) { exit 0 }",
		"    if (Save-DibAsBmp 'DeviceIndependentBitmap' $dst) { exit 0 }",
		"  }",
		"  default { throw ('Unsupported image extension: ' + $ext) }",
		"}",
		"$img = Get-ImageObject",
		"if (-not $img) { throw 'No image in clipboard' }",
		"$img.Save($dst, $fmt)",
	})

	script = script .. "; " .. ps.join(lines)
	local _, err, code = process.exec_ps(script, "10s")
	return code == 0, err
end

return M
