<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth_xml.php');
	require_once('includes/functions/dbConnect.php');
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

$statusQuery = "SELECT * FROM STATUS";

$statusResult=mysqli_query($link,$statusQuery);
if($statusResult) {
	if($statusResult->num_rows >= 1) {
		if ($statusFields = mysqli_fetch_assoc($statusResult)) {
			$user = htmlspecialchars($statusFields["user"], ENT_QUOTES);
			$pid = $statusFields["pid"];
			$ppid = $statusFields["ppid"];
			$c = $statusFields["c"];
			$stime = htmlspecialchars($statusFields["stime"], ENT_QUOTES);
			$tty = htmlspecialchars($statusFields["tty"], ENT_QUOTES);
			$time = htmlspecialchars($statusFields["time"], ENT_QUOTES);
			$cmd = htmlspecialchars($statusFields["cmd"], ENT_QUOTES);
		}
		else {
			$user = "N/A";
			$pid = "N/A";
			$ppid = "N/A";
			$c = "N/A";
			$stime = "N/A";
			$tty = "N/A";
			$time = "N/A";
			$cmd = "N/A";
		}
	}
	else {
		$user = "N/A";
		$pid = "N/A";
		$ppid = "N/A";
		$c = "N/A";
		$stime = "N/A";
		$tty = "N/A";
		$time = "N/A";
		$cmd = "N/A";
	}
}
else {
	$user = "N/A";
	$pid = "N/A";
	$ppid = "N/A";
	$c = "N/A";
	$stime = "N/A";
	$tty = "N/A";
	$time = "N/A";
	$cmd = "N/A";
}

$html = <<< EOH
      	<row id="$usersCellId">
      		<cell>$user</cell>
      		<cell>$pid</cell>
      		<cell>$ppid</cell>
      		<cell>$c</cell>
      		<cell>$stime</cell>
      		<cell>$tty</cell>
      		<cell>$time</cell>
      		<cell>$cmd</cell>
				</row>
EOH;

echo($html);

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
