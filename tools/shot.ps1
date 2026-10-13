# Captures the coopdx window (even when covered) with PrintWindow.
param([string]$out="shot.png")
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class W{
[DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out RECT r);
[DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
public struct RECT{public int L,T,R,B;}}
"@
$p=Get-Process sm64coopdx -ErrorAction Stop;$h=$p.MainWindowHandle;$r=New-Object W+RECT;[W]::GetClientRect($h,[ref]$r)|Out-Null
$w=$r.R-$r.L;$hh=$r.B-$r.T;$bmp=New-Object Drawing.Bitmap $w,$hh;$g=[Drawing.Graphics]::FromImage($bmp)
$dc=$g.GetHdc();[W]::PrintWindow($h,$dc,3)|Out-Null;$g.ReleaseHdc($dc)
$bmp.Save($out);"$w x $hh"
