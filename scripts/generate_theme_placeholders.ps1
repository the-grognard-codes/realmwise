# Deterministically derive theme variants from the approved Dragon Red source.
# The source's gold compass/title pixels are copied unchanged; only background
# pixels are remapped. Secondary colors are tasteful companions where the app
# does not define an explicit secondary palette.

Add-Type -AssemblyName System.Drawing
$refs = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | Select-Object -ExpandProperty Location -Unique
Add-Type -ReferencedAssemblies $refs @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class PlaceholderRenderer {
  public static void Render(string source, string output, int pr, int pg, int pb, int sr, int sg, int sb) {
    using (var src = new Bitmap(source)) using (var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(dst)) g.DrawImageUnscaled(src, 0, 0);
      var rect = new Rectangle(0, 0, src.Width, src.Height);
      var s = src.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var d = dst.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
      int n = Math.Abs(s.Stride) * src.Height; var a = new byte[n]; var b = new byte[n];
      Marshal.Copy(s.Scan0, a, 0, n); Marshal.Copy(d.Scan0, b, 0, n);
      for (int y=0; y<src.Height; y++) for (int x=0; x<src.Width; x++) {
        int i = y*Math.Abs(s.Stride)+x*4; int blue=a[i], green=a[i+1], red=a[i+2];
        // Gold foreground includes dark bronze bevels/shadows. The broader
        // chroma/luminance mask retains those pixels (and antialiased edges)
        // while excluding the red sponge background, whose green/blue channels
        // remain very low. This keeps the compass and lettering byte-identical.
        bool gold = green >= red*0.42 && blue >= red*0.12 && red+green+blue >= 180;
        if (gold) { b[i]=a[i]; b[i+1]=a[i+1]; b[i+2]=a[i+2]; b[i+3]=a[i+3]; continue; }
        double lum=.299*red+.587*green+.114*blue, t=Math.Max(0,Math.Min(1,(lum-8)/150));
        b[i]=(byte)Math.Max(0,Math.Min(255,Math.Round(sb+(pb-sb)*t)));
        b[i+1]=(byte)Math.Max(0,Math.Min(255,Math.Round(sg+(pg-sg)*t)));
        b[i+2]=(byte)Math.Max(0,Math.Min(255,Math.Round(sr+(pr-sr)*t))); b[i+3]=a[i+3];
      }
      Marshal.Copy(b, 0, d.Scan0, n); dst.UnlockBits(d); src.UnlockBits(s); dst.Save(output, ImageFormat.Png);
    }
  }
}
'@

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'assets/placeholders/work-cover-placeholder-unavailable-dragon-red.png'
$outDir = Join-Path $root 'assets/placeholders'

# Primary values mirror lib/theme/app_theme.dart. Companions preserve contrast
# and sponge variation while remaining visually related to each theme seed.
$themes = [ordered]@{
  'parchment-gold' = @('#C28E2B', '#6B3E18')
  'dungeon-black'  = @('#24201C', '#080706')
  'arcane-blue'    = @('#254C7A', '#101F3A')
  'forest-green'   = @('#385C37', '#102B20')
  'royal-purple'   = @('#5D3A78', '#24132F')
  'teal-sigil'     = @('#176B6B', '#082F3A')
  'greyscale'      = @('#666666', '#202020')
}

function Convert-HexColor([string]$hex) {
  return [Drawing.Color]::FromArgb(
    [Convert]::ToInt32($hex.Substring(1, 2), 16),
    [Convert]::ToInt32($hex.Substring(3, 2), 16),
    [Convert]::ToInt32($hex.Substring(5, 2), 16))
}

function Clamp([double]$v) { return [Math]::Max(0, [Math]::Min(255, [Math]::Round($v))) }

$src = [Drawing.Bitmap]::new($sourcePath)
try {
  foreach ($entry in $themes.GetEnumerator()) {
    $primary = Convert-HexColor $entry.Value[0]
    $secondary = Convert-HexColor $entry.Value[1]
    $outPath = Join-Path $outDir ("work-cover-placeholder-unavailable-{0}.png" -f $entry.Key)
    [PlaceholderRenderer]::Render($sourcePath, $outPath, $primary.R, $primary.G, $primary.B, $secondary.R, $secondary.G, $secondary.B)
    Write-Output ("{0}: {1}x{2}" -f $outPath, $src.Width, $src.Height)
  }
} finally { $src.Dispose() }
