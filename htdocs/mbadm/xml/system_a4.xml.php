<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');

	$procInfoExec = exec("ps -eafw",$procInfoResults);
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

for($i=1;$i<sizeof($procInfoResults);$i++) {

$procInfoResults2 = preg_split ( "/\s+/" , $procInfoResults[$i] ) ;

$UID = $procInfoResults2[0];
$PID = $procInfoResults2[1];
$PPID = $procInfoResults2[2];
//$C = $procInfoResults2[3];
$STIME = $procInfoResults2[4];
$TTY = $procInfoResults2[5];
$TIME = $procInfoResults2[6];
$CMD = $procInfoResults2[7];
if ( $PPID != 2 ) {

$html = <<< EOH
      	<row id="processId$i">
	   			<cell>$UID</cell>
	   			<cell>$PID</cell>
	   			<cell>$PPID</cell>
	   			<cell>$CMD</cell>
	   			<cell>$STIME</cell>
	   			<cell>$TTY</cell>
	   			<cell>$TIME</cell>
				</row>

EOH;

echo($html);
}
}

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
