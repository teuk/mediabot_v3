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

mysqli_query($link,"SET NAMES 'utf8'");
mysqli_query($link,"SET CHARACTER SET utf8");
mysqli_query($link,"SET COLLATION_CONNECTION = 'utf8_general_ci'");

$id_channel = $_GET["id_channel"];

$channelLogsQuery = "SELECT * FROM CHANNEL_LOG WHERE (ts BETWEEN DATE_SUB(NOW(), INTERVAL 3 DAY)  AND NOW()) AND id_channel=$id_channel ORDER by ts";

$channelLogsResult=mysqli_query($link,$channelLogsQuery);
if($channelLogsResult) {
	if($channelLogsResult->num_rows >= 1) {
		$channelLineCount = 0;
		while ($channelLogsFields = mysqli_fetch_assoc($channelLogsResult)) {
			// Date Heure,ȶ筥ment,Nick,Hostmask,Texte");
			$id_channel_log = $channelLogsFields["id_channel_log"];
			$ts = $channelLogsFields["ts"];
			$time = strtotime($ts) - 21600;
			$myFormatForView = date("d/m/Y H:i:s", $time);
			$event_type = htmlspecialchars($channelLogsFields["event_type"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			$nick = htmlspecialchars($channelLogsFields["nick"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			$userhost = htmlspecialchars($channelLogsFields["userhost"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			$publictext = htmlspecialchars($channelLogsFields["publictext"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			if ( $event_type == "public" ) {
				$displaytext = "[$nick] $publictext";
			}
			elseif ( $event_type == "join" ) {
				$displaytext = "Joins: $nick($userhost)";
			}
			elseif ( $event_type == "part" ) {
				$displaytext = "Parts: $nick($userhost)";
			}
			elseif ( $event_type == "mode" ) {
				$displaytext = "$nick $publictext";
			}
			elseif ( $event_type == "caction" ) {
				$displaytext = "$nick $publictext";
			}
			elseif ( $event_type == "kick" ) {
				$displaytext = "$publictext";
			}
			else {
				$displaytext = "$event_type";
			}

$html = <<< EOH
      	<row id="channelLine$channelLineCount">
      		<cell>$myFormatForView</cell>
      		<cell>$displaytext</cell>
				</row>
EOH;

			echo($html);
			$channelLineCount++;
		}
	}
}


$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
