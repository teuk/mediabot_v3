<?php
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = 1;
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
?>
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta name="generator"  content="lshw-B.02.17" />
<style type="text/css">
  .first {font-weight: bold; margin-left: none; padding-right: 1em;vertical-align: top; }
  .second {padding-left: 1em; width: 100%; vertical-align: center; }
  .id {font-family: monospace;}
  .indented {margin-left: 2em; border-left: dotted thin #dde; padding-bottom: 1em; }
  .node {border: solid thin #ffcc66; padding: 1em; background: #ffffcc; }
  .node-unclaimed {border: dotted thin #c3c3c3; padding: 1em; background: #fafafa; color: red; }
  .node-disabled {border: solid thin #f55; padding: 1em; background: #fee; color: gray; }
</style>
<title>teuk.org</title>
</head>
<body>
<div class="indented">
<table width="100%" class="node" summary="attributes of teuk.org">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">teuk.org</div></td></tr></thead>
 <tbody>
    <tr><td class="first">description: </td><td class="second">Computer</td></tr>
    <tr><td class="first">width: </td><td class="second">64 bits</td></tr>
    <tr><td class="first">capabilities: </td><td class="second"><dfn title="SMBIOS version 2.7">smbios-2.7</dfn> <dfn title="32-bit processes">vsyscall32</dfn> </td></tr>
 </tbody></table></div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node" summary="attributes of core">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">core</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">Motherboard</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">2</div></td></tr>
 </tbody>    </table></div>
<div class="indented">
              <div class="indented">
       <table width="100%" class="node" summary="attributes of memory">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">memory</div></td></tr></thead>
 <tbody>
          <tr><td class="first">description: </td><td class="second">System memory</td></tr>
          <tr><td class="first">physical id: </td><td class="second"><div class="id">0</div></td></tr>
          <tr><td class="first">size: </td><td class="second">3926MiB</td></tr>
 </tbody>       </table></div>
       </div>
<div class="indented">
              <div class="indented">
       <table width="100%" class="node" summary="attributes of cpu">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">cpu</div></td></tr></thead>
 <tbody>
          <tr><td class="first">product: </td><td class="second">Intel(R) Atom(TM) CPU N2800   @ 1.86GHz</td></tr>
          <tr><td class="first">vendor: </td><td class="second">Intel Corp.</td></tr>
          <tr><td class="first">physical id: </td><td class="second"><div class="id">1</div></td></tr>
          <tr><td class="first">bus info: </td><td class="second"><div class="id">cpu@0</div></td></tr>
          <tr><td class="first">size: </td><td class="second">798MHz</td></tr>
          <tr><td class="first">capacity: </td><td class="second">1862MHz</td></tr>
          <tr><td class="first">width: </td><td class="second">64 bits</td></tr>
          <tr><td class="first">capabilities: </td><td class="second"><dfn title="mathematical co-processor">fpu</dfn> <dfn title="FPU exceptions reporting">fpu_exception</dfn> <dfn title="">wp</dfn> <dfn title="virtual mode extensions">vme</dfn> <dfn title="debugging extensions">de</dfn> <dfn title="page size extensions">pse</dfn> <dfn title="time stamp counter">tsc</dfn> <dfn title="model-specific registers">msr</dfn> <dfn title="4GB+ memory addressing (Physical Address Extension)">pae</dfn> <dfn title="machine check exceptions">mce</dfn> <dfn title="compare and exchange 8-byte">cx8</dfn> <dfn title="on-chip advanced programmable interrupt controller (APIC)">apic</dfn> <dfn title="fast system calls">sep</dfn> <dfn title="memory type range registers">mtrr</dfn> <dfn title="page global enable">pge</dfn> <dfn title="machine check architecture">mca</dfn> <dfn title="conditional move instruction">cmov</dfn> <dfn title="page attribute table">pat</dfn> <dfn title="36-bit page size extensions">pse36</dfn> <dfn title="">clflush</dfn> <dfn title="debug trace and EMON store MSRs">dts</dfn> <dfn title="thermal control (ACPI)">acpi</dfn> <dfn title="multimedia extensions (MMX)">mmx</dfn> <dfn title="fast floating point save/restore">fxsr</dfn> <dfn title="streaming SIMD extensions (SSE)">sse</dfn> <dfn title="streaming SIMD extensions (SSE2)">sse2</dfn> <dfn title="self-snoop">ss</dfn> <dfn title="HyperThreading">ht</dfn> <dfn title="thermal interrupt and status">tm</dfn> <dfn title="pending break event">pbe</dfn> <dfn title="fast system calls">syscall</dfn> <dfn title="no-execute bit (NX)">nx</dfn> <dfn title="64bits extensions (x86-64)">x86-64</dfn> <dfn title="">constant_tsc</dfn> <dfn title="">arch_perfmon</dfn> <dfn title="">pebs</dfn> <dfn title="">bts</dfn> <dfn title="">nopl</dfn> <dfn title="">nonstop_tsc</dfn> <dfn title="">aperfmperf</dfn> <dfn title="">pni</dfn> <dfn title="">dtes64</dfn> <dfn title="">monitor</dfn> <dfn title="">ds_cpl</dfn> <dfn title="">est</dfn> <dfn title="">tm2</dfn> <dfn title="">ssse3</dfn> <dfn title="">cx16</dfn> <dfn title="">xtpr</dfn> <dfn title="">pdcm</dfn> <dfn title="">movbe</dfn> <dfn title="">lahf_lm</dfn> <dfn title="">arat</dfn> <dfn title="">dtherm</dfn> <dfn title="CPU Frequency scaling">cpufreq</dfn> </td></tr>
 </tbody>       </table></div>
       </div>
<div class="indented">
              <div class="indented">
       <table width="100%" class="node" summary="attributes of pci">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">pci</div></td></tr></thead>
 <tbody>
          <tr><td class="first">description: </td><td class="second">Host bridge</td></tr>
          <tr><td class="first">product: </td><td class="second">Atom Processor D2xxx/N2xxx DRAM Controller</td></tr>
          <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
          <tr><td class="first">physical id: </td><td class="second"><div class="id">100</div></td></tr>
          <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:00.0</div></td></tr>
          <tr><td class="first">version: </td><td class="second">03</td></tr>
          <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
          <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
 </tbody>       </table></div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node-unclaimed" summary="attributes of display">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">display</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">VGA compatible controller</td></tr>
             <tr><td class="first">product: </td><td class="second">Atom Processor D2xxx/N2xxx Integrated Graphics Controller</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">2</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:02.0</div></td></tr>
             <tr><td class="first">version: </td><td class="second">09</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Power Management">pm</dfn> <dfn title="Message Signalled Interrupts">msi</dfn> <dfn title="">vga_controller</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of display"><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of display"><tr><td class="sub-first"> memory</td><td>:</td><td>d0500000-d05fffff</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30d0(size=8)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of pci:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">pci:0</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">PCI bridge</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family PCI Express Port 1</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1c</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1c.0</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="">pci</dfn> <dfn title="PCI Express">pciexpress</dfn> <dfn title="Message Signalled Interrupts">msi</dfn> <dfn title="Power Management">pm</dfn> <dfn title="">normal_decode</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of pci:0"><tr><td class="sub-first"> driver</td><td>=</td><td>pcieport</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of pci:0"><tr><td class="sub-first"> irq</td><td>:</td><td>40</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>2000(size=4096)</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0000000-d04fffff</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>d0700000(size=2097152)</td></tr></table></td></tr>
 </tbody>          </table></div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of network">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">network</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">Ethernet interface</td></tr>
                <tr><td class="first">product: </td><td class="second">82574L Gigabit Network Connection</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">0</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:01:00.0</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">eth0</div></td></tr>
                <tr><td class="first">version: </td><td class="second">00</td></tr>
                <tr><td class="first">serial: </td><td class="second">00:22:4d:88:e2:49</td></tr>
                <tr><td class="first">size: </td><td class="second">1Gbit/s</td></tr>
                <tr><td class="first">capacity: </td><td class="second">1Gbit/s</td></tr>
                <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
                <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="Power Management">pm</dfn> <dfn title="Message Signalled Interrupts">msi</dfn> <dfn title="PCI Express">pciexpress</dfn> <dfn title="MSI-X">msix</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> <dfn title="">ethernet</dfn> <dfn title="Physical interface">physical</dfn> <dfn title="twisted pair">tp</dfn> <dfn title="10Mbit/s">10bt</dfn> <dfn title="10Mbit/s (full duplex)">10bt-fd</dfn> <dfn title="100Mbit/s">100bt</dfn> <dfn title="100Mbit/s (full duplex)">100bt-fd</dfn> <dfn title="1Gbit/s (full duplex)">1000bt-fd</dfn> <dfn title="Auto-negotiation">autonegotiation</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of network"><tr><td class="sub-first"> autonegotiation</td><td>=</td><td>on</td></tr><tr><td class="sub-first"> broadcast</td><td>=</td><td>yes</td></tr><tr><td class="sub-first"> driver</td><td>=</td><td>e1000e</td></tr><tr><td class="sub-first"> driverversion</td><td>=</td><td>3.2.4.2-NAPI</td></tr><tr><td class="sub-first"> duplex</td><td>=</td><td>full</td></tr><tr><td class="sub-first"> firmware</td><td>=</td><td>2.1-2</td></tr><tr><td class="sub-first"> ip</td><td>=</td><td>164.132.172.129</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr><tr><td class="sub-first"> link</td><td>=</td><td>yes</td></tr><tr><td class="sub-first"> multicast</td><td>=</td><td>yes</td></tr><tr><td class="sub-first"> port</td><td>=</td><td>twisted pair</td></tr><tr><td class="sub-first"> speed</td><td>=</td><td>1Gbit/s</td></tr></table></td></tr>
                <tr><td class="first">resources:</td><td class="second"><table summary="resources of network"><tr><td class="sub-first"> irq</td><td>:</td><td>16</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0400000-d041ffff</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0000000-d03fffff</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>2000(size=32)</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0420000-d0423fff</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of usb:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">usb:0</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">USB controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family USB UHCI Controller #1</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1d</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1d.0</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Universal Host Controller Interface (USB1)">uhci</dfn> <dfn title="bus mastering">bus_master</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of usb:0"><tr><td class="sub-first"> driver</td><td>=</td><td>uhci_hcd</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of usb:0"><tr><td class="sub-first"> irq</td><td>:</td><td>23</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30a0(size=32)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of usb:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">usb:1</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">USB controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family USB UHCI Controller #2</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1d.1</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1d.1</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Universal Host Controller Interface (USB1)">uhci</dfn> <dfn title="bus mastering">bus_master</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of usb:1"><tr><td class="sub-first"> driver</td><td>=</td><td>uhci_hcd</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of usb:1"><tr><td class="sub-first"> irq</td><td>:</td><td>19</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>3080(size=32)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of usb:2">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">usb:2</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">USB controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family USB UHCI Controller #3</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1d.2</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1d.2</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Universal Host Controller Interface (USB1)">uhci</dfn> <dfn title="bus mastering">bus_master</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of usb:2"><tr><td class="sub-first"> driver</td><td>=</td><td>uhci_hcd</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of usb:2"><tr><td class="sub-first"> irq</td><td>:</td><td>18</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>3060(size=32)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of usb:3">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">usb:3</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">USB controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family USB UHCI Controller #4</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1d.3</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1d.3</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Universal Host Controller Interface (USB1)">uhci</dfn> <dfn title="bus mastering">bus_master</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of usb:3"><tr><td class="sub-first"> driver</td><td>=</td><td>uhci_hcd</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of usb:3"><tr><td class="sub-first"> irq</td><td>:</td><td>16</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>3040(size=32)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of usb:4">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">usb:4</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">USB controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family USB2 EHCI Controller</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1d.7</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1d.7</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="Power Management">pm</dfn> <dfn title="Debug port">debug</dfn> <dfn title="Enhanced Host Controller Interface (USB2)">ehci</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of usb:4"><tr><td class="sub-first"> driver</td><td>=</td><td>ehci-pci</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of usb:4"><tr><td class="sub-first"> irq</td><td>:</td><td>23</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0600400-d06007ff</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of pci:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">pci:1</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">PCI bridge</td></tr>
             <tr><td class="first">product: </td><td class="second">82801 Mobile PCI Bridge</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1e</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1e.0</div></td></tr>
             <tr><td class="first">version: </td><td class="second">e2</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="">pci</dfn> <dfn title="">subtractive_decode</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of isa">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">isa</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">ISA bridge</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10 Family LPC Controller</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1f</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1f.0</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="">isa</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of isa"><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of storage">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">storage</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">SATA controller</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family SATA Controller [AHCI mode]</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1f.2</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1f.2</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">66MHz</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="">storage</dfn> <dfn title="Message Signalled Interrupts">msi</dfn> <dfn title="Power Management">pm</dfn> <dfn title="">ahci_1.0</dfn> <dfn title="bus mastering">bus_master</dfn> <dfn title="PCI capabilities listing">cap_list</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of storage"><tr><td class="sub-first"> driver</td><td>=</td><td>ahci</td></tr><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of storage"><tr><td class="sub-first"> irq</td><td>:</td><td>41</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30c8(size=8)</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30dc(size=4)</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30c0(size=8)</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>30d8(size=4)</td></tr><tr><td class="sub-first"> ioport</td><td>:</td><td>3020(size=16)</td></tr><tr><td class="sub-first"> memory</td><td>:</td><td>d0600000-d06003ff</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node-unclaimed" summary="attributes of serial">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">serial</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">SMBus</td></tr>
             <tr><td class="first">product: </td><td class="second">NM10/ICH7 Family SMBus Controller</td></tr>
             <tr><td class="first">vendor: </td><td class="second">Intel Corporation</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">1f.3</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">pci@0000:00:1f.3</div></td></tr>
             <tr><td class="first">version: </td><td class="second">02</td></tr>
             <tr><td class="first">width: </td><td class="second">32 bits</td></tr>
             <tr><td class="first">clock: </td><td class="second">33MHz</td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of serial"><tr><td class="sub-first"> latency</td><td>=</td><td>0</td></tr></table></td></tr>
             <tr><td class="first">resources:</td><td class="second"><table summary="resources of serial"><tr><td class="sub-first"> ioport</td><td>:</td><td>3000(size=32)</td></tr></table></td></tr>
 </tbody>          </table></div>
          </div>
       </div>
<div class="indented">
              <div class="indented">
       <table width="100%" class="node" summary="attributes of scsi:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">scsi:0</div></td></tr></thead>
 <tbody>
          <tr><td class="first">physical id: </td><td class="second"><div class="id">2</div></td></tr>
          <tr><td class="first">logical name: </td><td class="second"><div class="id">scsi0</div></td></tr>
          <tr><td class="first">capabilities: </td><td class="second"><dfn title="Emulated device">emulated</dfn> </td></tr>
 </tbody>       </table></div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of disk">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">disk</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">ATA Disk</td></tr>
             <tr><td class="first">product: </td><td class="second">HGST HUS724020AL</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">0.0.0</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@0:0.0.0</div></td></tr>
             <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sda</div></td></tr>
             <tr><td class="first">version: </td><td class="second">MF6O</td></tr>
             <tr><td class="first">serial: </td><td class="second">PN1134P6KUMTXW</td></tr>
             <tr><td class="first">size: </td><td class="second">1863GiB (2TB)</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="GUID Partition Table version 1.00">gpt-1.00</dfn> <dfn title="Partitioned disk">partitioned</dfn> <dfn title="GUID partition table">partitioned:gpt</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of disk"><tr><td class="sub-first"> ansiversion</td><td>=</td><td>5</td></tr><tr><td class="sub-first"> guid</td><td>=</td><td>f32235d5-1125-470f-b481-1bc52fadcf80</td></tr><tr><td class="sub-first"> logicalsectorsize</td><td>=</td><td>512</td></tr><tr><td class="sub-first"> sectorsize</td><td>=</td><td>512</td></tr></table></td></tr>
 </tbody>          </table></div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:0</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">BIOS Boot partition</td></tr>
                <tr><td class="first">vendor: </td><td class="second">EFI</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">1</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@0:0.0.0,1</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sda1</div></td></tr>
                <tr><td class="first">serial: </td><td class="second">f27590c4-6ef1-4080-9acf-d30b8a6f5329</td></tr>
                <tr><td class="first">capacity: </td><td class="second">1004KiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="No filesystem">nofs</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:0"><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:1</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">EXT4 volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">2</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@0:0.0.0,2</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sda2</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1.0</td></tr>
                <tr><td class="first">serial: </td><td class="second">81d3a2d5-9b82-4f73-a837-23f0681aa6e8</td></tr>
                <tr><td class="first">size: </td><td class="second">19GiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">19GiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="Multi-volumes">multi</dfn> <dfn title="">journaled</dfn> <dfn title="Extended Attributes">extended_attributes</dfn> <dfn title="4GB+ files">large_files</dfn> <dfn title="16TB+ files">huge_files</dfn> <dfn title="directories with 65000+ subdirs">dir_nlink</dfn> <dfn title="extent-based allocation">extents</dfn> <dfn title="">ext4</dfn> <dfn title="EXT2/EXT3">ext2</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:1"><tr><td class="sub-first"> created</td><td>=</td><td>2016-05-03 23:31:20</td></tr><tr><td class="sub-first"> filesystem</td><td>=</td><td>ext4</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>/</td></tr><tr><td class="sub-first"> lastmountpoint</td><td>=</td><td>/</td></tr><tr><td class="sub-first"> modified</td><td>=</td><td>2016-05-24 07:54:16</td></tr><tr><td class="sub-first"> mounted</td><td>=</td><td>2016-05-21 10:32:32</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> state</td><td>=</td><td>clean</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:2">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:2</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">EXT4 volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">3</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@0:0.0.0,3</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sda3</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1.0</td></tr>
                <tr><td class="first">serial: </td><td class="second">57232267-22f8-479f-993c-886be18ac0f3</td></tr>
                <tr><td class="first">size: </td><td class="second">1842GiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">1842GiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="Multi-volumes">multi</dfn> <dfn title="">journaled</dfn> <dfn title="Extended Attributes">extended_attributes</dfn> <dfn title="4GB+ files">large_files</dfn> <dfn title="16TB+ files">huge_files</dfn> <dfn title="directories with 65000+ subdirs">dir_nlink</dfn> <dfn title="needs recovery">recover</dfn> <dfn title="extent-based allocation">extents</dfn> <dfn title="">ext4</dfn> <dfn title="EXT2/EXT3">ext2</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:2"><tr><td class="sub-first"> created</td><td>=</td><td>2016-05-03 23:31:30</td></tr><tr><td class="sub-first"> filesystem</td><td>=</td><td>ext4</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>/home</td></tr><tr><td class="sub-first"> lastmountpoint</td><td>=</td><td>/home</td></tr><tr><td class="sub-first"> modified</td><td>=</td><td>2016-05-24 07:54:18</td></tr><tr><td class="sub-first"> mounted</td><td>=</td><td>2016-05-24 07:54:18</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> state</td><td>=</td><td>clean</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:3">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:3</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">Linux swap volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">4</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@0:0.0.0,4</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sda4</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1</td></tr>
                <tr><td class="first">serial: </td><td class="second">e97b4ad5-87bc-45e9-9baa-f5f3160a31e6</td></tr>
                <tr><td class="first">size: </td><td class="second">510MiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">510MiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="No filesystem">nofs</dfn> <dfn title="Linux swap">swap</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:3"><tr><td class="sub-first"> filesystem</td><td>=</td><td>swap</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>swap-sda4</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> pagesize</td><td>=</td><td>4095</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
          </div>
       </div>
<div class="indented">
              <div class="indented">
       <table width="100%" class="node" summary="attributes of scsi:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">scsi:1</div></td></tr></thead>
 <tbody>
          <tr><td class="first">physical id: </td><td class="second"><div class="id">3</div></td></tr>
          <tr><td class="first">logical name: </td><td class="second"><div class="id">scsi1</div></td></tr>
          <tr><td class="first">capabilities: </td><td class="second"><dfn title="Emulated device">emulated</dfn> </td></tr>
 </tbody>       </table></div>
<div class="indented">
                    <div class="indented">
          <table width="100%" class="node" summary="attributes of disk">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">disk</div></td></tr></thead>
 <tbody>
             <tr><td class="first">description: </td><td class="second">ATA Disk</td></tr>
             <tr><td class="first">product: </td><td class="second">HGST HUS724020AL</td></tr>
             <tr><td class="first">physical id: </td><td class="second"><div class="id">0.0.0</div></td></tr>
             <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@1:0.0.0</div></td></tr>
             <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sdb</div></td></tr>
             <tr><td class="first">version: </td><td class="second">MF6O</td></tr>
             <tr><td class="first">serial: </td><td class="second">PN2134P6JLENBP</td></tr>
             <tr><td class="first">size: </td><td class="second">1863GiB (2TB)</td></tr>
             <tr><td class="first">capabilities: </td><td class="second"><dfn title="GUID Partition Table version 1.00">gpt-1.00</dfn> <dfn title="Partitioned disk">partitioned</dfn> <dfn title="GUID partition table">partitioned:gpt</dfn> </td></tr>
             <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of disk"><tr><td class="sub-first"> ansiversion</td><td>=</td><td>5</td></tr><tr><td class="sub-first"> guid</td><td>=</td><td>df998766-b119-449e-aeca-3dffaaab1575</td></tr><tr><td class="sub-first"> logicalsectorsize</td><td>=</td><td>512</td></tr><tr><td class="sub-first"> sectorsize</td><td>=</td><td>512</td></tr></table></td></tr>
 </tbody>          </table></div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:0</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">BIOS Boot partition</td></tr>
                <tr><td class="first">vendor: </td><td class="second">EFI</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">1</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@1:0.0.0,1</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sdb1</div></td></tr>
                <tr><td class="first">serial: </td><td class="second">e4bd2790-f03e-41d9-8c3a-1381455dbeee</td></tr>
                <tr><td class="first">capacity: </td><td class="second">1004KiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="No filesystem">nofs</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:0"><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:1</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">EXT4 volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">2</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@1:0.0.0,2</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sdb2</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1.0</td></tr>
                <tr><td class="first">serial: </td><td class="second">81d3a2d5-9b82-4f73-a837-23f0681aa6e8</td></tr>
                <tr><td class="first">size: </td><td class="second">19GiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">19GiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="Multi-volumes">multi</dfn> <dfn title="">journaled</dfn> <dfn title="Extended Attributes">extended_attributes</dfn> <dfn title="4GB+ files">large_files</dfn> <dfn title="16TB+ files">huge_files</dfn> <dfn title="directories with 65000+ subdirs">dir_nlink</dfn> <dfn title="extent-based allocation">extents</dfn> <dfn title="">ext4</dfn> <dfn title="EXT2/EXT3">ext2</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:1"><tr><td class="sub-first"> created</td><td>=</td><td>2016-05-03 23:31:20</td></tr><tr><td class="sub-first"> filesystem</td><td>=</td><td>ext4</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>/</td></tr><tr><td class="sub-first"> lastmountpoint</td><td>=</td><td>/</td></tr><tr><td class="sub-first"> modified</td><td>=</td><td>2016-05-24 07:54:16</td></tr><tr><td class="sub-first"> mounted</td><td>=</td><td>2016-05-21 10:32:32</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> state</td><td>=</td><td>clean</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:2">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:2</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">EXT4 volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">3</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@1:0.0.0,3</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sdb3</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1.0</td></tr>
                <tr><td class="first">serial: </td><td class="second">57232267-22f8-479f-993c-886be18ac0f3</td></tr>
                <tr><td class="first">size: </td><td class="second">1842GiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">1842GiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="Multi-volumes">multi</dfn> <dfn title="">journaled</dfn> <dfn title="Extended Attributes">extended_attributes</dfn> <dfn title="4GB+ files">large_files</dfn> <dfn title="16TB+ files">huge_files</dfn> <dfn title="directories with 65000+ subdirs">dir_nlink</dfn> <dfn title="needs recovery">recover</dfn> <dfn title="extent-based allocation">extents</dfn> <dfn title="">ext4</dfn> <dfn title="EXT2/EXT3">ext2</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:2"><tr><td class="sub-first"> created</td><td>=</td><td>2016-05-03 23:31:30</td></tr><tr><td class="sub-first"> filesystem</td><td>=</td><td>ext4</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>/home</td></tr><tr><td class="sub-first"> lastmountpoint</td><td>=</td><td>/home</td></tr><tr><td class="sub-first"> modified</td><td>=</td><td>2016-05-24 07:54:18</td></tr><tr><td class="sub-first"> mounted</td><td>=</td><td>2016-05-24 07:54:18</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> state</td><td>=</td><td>clean</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
<div class="indented">
                          <div class="indented">
             <table width="100%" class="node" summary="attributes of volume:3">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">volume:3</div></td></tr></thead>
 <tbody>
                <tr><td class="first">description: </td><td class="second">Linux swap volume</td></tr>
                <tr><td class="first">vendor: </td><td class="second">Linux</td></tr>
                <tr><td class="first">physical id: </td><td class="second"><div class="id">4</div></td></tr>
                <tr><td class="first">bus info: </td><td class="second"><div class="id">scsi@1:0.0.0,4</div></td></tr>
                <tr><td class="first">logical name: </td><td class="second"><div class="id">/dev/sdb4</div></td></tr>
                <tr><td class="first">version: </td><td class="second">1</td></tr>
                <tr><td class="first">serial: </td><td class="second">dc7d7ad5-b323-47a8-b10c-fd8dabfa7100</td></tr>
                <tr><td class="first">size: </td><td class="second">510MiB</td></tr>
                <tr><td class="first">capacity: </td><td class="second">510MiB</td></tr>
                <tr><td class="first">capabilities: </td><td class="second"><dfn title="No filesystem">nofs</dfn> <dfn title="Linux swap">swap</dfn> <dfn title="initialized volume">initialized</dfn> </td></tr>
                <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of volume:3"><tr><td class="sub-first"> filesystem</td><td>=</td><td>swap</td></tr><tr><td class="sub-first"> label</td><td>=</td><td>swap-sdb4</td></tr><tr><td class="sub-first"> name</td><td>=</td><td>primary</td></tr><tr><td class="sub-first"> pagesize</td><td>=</td><td>4095</td></tr></table></td></tr>
 </tbody>             </table></div>
             </div>
          </div>
       </div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node" summary="attributes of ide:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">ide:0</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">IDE Channel 0</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">0</div></td></tr>
       <tr><td class="first">bus info: </td><td class="second"><div class="id">ide@0</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">ide0</div></td></tr>
 </tbody>    </table></div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node" summary="attributes of ide:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">ide:1</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">IDE Channel 0</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">1</div></td></tr>
       <tr><td class="first">bus info: </td><td class="second"><div class="id">ide@1</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">ide1</div></td></tr>
 </tbody>    </table></div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node-disabled" summary="attributes of network:0">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">network:0</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">Ethernet interface</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">3</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">dummy0</div></td></tr>
       <tr><td class="first">serial: </td><td class="second">a2:7a:cf:88:0c:38</td></tr>
       <tr><td class="first">capabilities: </td><td class="second"><dfn title="">ethernet</dfn> <dfn title="Physical interface">physical</dfn> </td></tr>
       <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of network:0"><tr><td class="sub-first"> broadcast</td><td>=</td><td>yes</td></tr></table></td></tr>
 </tbody>    </table></div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node-disabled" summary="attributes of network:1">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">network:1</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">Ethernet interface</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">4</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">bond0</div></td></tr>
       <tr><td class="first">serial: </td><td class="second">26:58:c4:f5:c5:9a</td></tr>
       <tr><td class="first">capabilities: </td><td class="second"><dfn title="">ethernet</dfn> <dfn title="Physical interface">physical</dfn> </td></tr>
       <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of network:1"><tr><td class="sub-first"> autonegotiation</td><td>=</td><td>off</td></tr><tr><td class="sub-first"> broadcast</td><td>=</td><td>yes</td></tr><tr><td class="sub-first"> driver</td><td>=</td><td>bonding</td></tr><tr><td class="sub-first"> driverversion</td><td>=</td><td>3.7.1</td></tr><tr><td class="sub-first"> firmware</td><td>=</td><td>2</td></tr><tr><td class="sub-first"> link</td><td>=</td><td>no</td></tr><tr><td class="sub-first"> master</td><td>=</td><td>yes</td></tr><tr><td class="sub-first"> multicast</td><td>=</td><td>yes</td></tr></table></td></tr>
 </tbody>    </table></div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node-disabled" summary="attributes of network:2">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">network:2</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">Ethernet interface</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">5</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">ifb0</div></td></tr>
       <tr><td class="first">serial: </td><td class="second">96:62:3d:af:35:d5</td></tr>
       <tr><td class="first">capabilities: </td><td class="second"><dfn title="">ethernet</dfn> <dfn title="Physical interface">physical</dfn> </td></tr>
       <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of network:2"><tr><td class="sub-first"> broadcast</td><td>=</td><td>yes</td></tr></table></td></tr>
 </tbody>    </table></div>
    </div>
<div class="indented">
        <div class="indented">
    <table width="100%" class="node-disabled" summary="attributes of network:3">
 <thead><tr><td class="first">id:</td><td class="second"><div class="id">network:3</div></td></tr></thead>
 <tbody>
       <tr><td class="first">description: </td><td class="second">Ethernet interface</td></tr>
       <tr><td class="first">physical id: </td><td class="second"><div class="id">6</div></td></tr>
       <tr><td class="first">logical name: </td><td class="second"><div class="id">ifb1</div></td></tr>
       <tr><td class="first">serial: </td><td class="second">76:52:b5:99:19:0b</td></tr>
       <tr><td class="first">capabilities: </td><td class="second"><dfn title="">ethernet</dfn> <dfn title="Physical interface">physical</dfn> </td></tr>
       <tr><td class="first">configuration:</td><td class="second"><table summary="configuration of network:3"><tr><td class="sub-first"> broadcast</td><td>=</td><td>yes</td></tr></table></td></tr>
 </tbody>    </table></div>
    </div>
</body>
</html>
