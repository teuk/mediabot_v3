<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');

	$uptimeInfoExec = exec("uptime",$uptimeInfoResults);
	$freeInfoExec = exec("free -m | grep ^Mem | awk '{print $2 \" \" $3}'",$freeInfoResults);
	$cpuLoadExec = exec("vmstat 1 2 | tail -n 1 | awk '{print $15}'",$cpuLoadResults);
	$processCountExec = exec("ps -eaf | grep -v ^UID | wc -l",$processCountResults);
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

$cellId = 0;

for($i=0;$i<sizeof($uptimeInfoResults);$i++) {

	$specification = "Uptime";
	$specificationValue = $uptimeInfoResults[$i];
	
$html = <<< EOH
      	<row id="sysInfoId$cellId">
	   			<cell>$specification</cell>
	   			<cell>$specificationValue</cell>
				</row>

EOH;

	echo($html);
	$cellId++;
}

for($i=0;$i<sizeof($freeInfoResults);$i++) {
	$freeInfoResults2 = preg_split ( "/\s/" , $freeInfoResults[$i] ) ;

	for($j=0;$j<sizeof($freeInfoResults2);$j++) {
		if ( $j == 0 ) {
			$specification = "Total Memory";
		}
		elseif ( $j == 1 ) {
			$specification = "Used Memory";
		}
		
		$specificationValue = $freeInfoResults2[$j] . " MB";
	
	
$html = <<< EOH
      	<row id="sysInfoId$cellId">
	   			<cell>$specification</cell>
	   			<cell>$specificationValue</cell>
				</row>

EOH;

		echo($html);
		$cellId++;
	}
}

for($i=0;$i<sizeof($cpuLoadResults);$i++) {

	$specification = "CPU Load";
	$specificationValue = (100 - $cpuLoadResults[$i]) . " %";
	
$html = <<< EOH
      	<row id="sysInfoId$cellId">
	   			<cell>$specification</cell>
	   			<cell>$specificationValue</cell>
				</row>

EOH;

	echo($html);
	$cellId++;
}

for($i=0;$i<sizeof($processCountResults);$i++) {

	$specification = "Processes";
	$specificationValue = $processCountResults[$i];
	
$html = <<< EOH
      	<row id="sysInfoId$cellId">
	   			<cell>$specification</cell>
	   			<cell>$specificationValue</cell>
				</row>

EOH;

	echo($html);
	$cellId++;
}

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
