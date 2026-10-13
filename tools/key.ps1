param([string[]]$keys,[int]$hold=80,[int]$gap=150)
Add-Type @"
using System;using System.Runtime.InteropServices;
public class K{[DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte scan,uint flags,UIntPtr extra);
[DllImport("user32.dll")]public static extern uint MapVirtualKey(uint code,uint type);
[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}
"@
$p=Get-Process sm64coopdx -ErrorAction Stop;[K]::SetForegroundWindow($p.MainWindowHandle)|Out-Null;Start-Sleep -Milliseconds 200
foreach($k in $keys){
  $parts=$k.Split(':');$vk=[byte][Convert]::ToInt32($parts[0],16);$ms=if($parts.Length -gt 1){[int]$parts[1]}else{$hold}
  $sc=[byte][K]::MapVirtualKey($vk,0)
  [K]::keybd_event($vk,$sc,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds $ms;[K]::keybd_event($vk,$sc,2,[UIntPtr]::Zero);Start-Sleep -Milliseconds $gap
}
