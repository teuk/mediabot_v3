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

$id_channel = $_GET['id_channel'];

$channelQuery = "SELECT * FROM CHANNEL WHERE CHANNEL.id_channel=$id_channel";

$channelResult=mysqli_query($link,$channelQuery);
if($channelResult) {
	if($channelResult->num_rows >= 1) {
		if ($channelFields = mysqli_fetch_assoc($channelResult)) {
			$id_channel = $channelFields["id_channel"];
			$name = htmlspecialchars($channelFields["name"], ENT_QUOTES);
			$description = htmlspecialchars($channelFields["description"], ENT_QUOTES);
			$key = htmlspecialchars($channelFields["key"], ENT_QUOTES);
			$chanmode = htmlspecialchars($channelFields["chanmode"], ENT_QUOTES);

$html = <<< EOH
      	<row id="$id_channel">
      		<cell>$id_channel</cell>
      		<cell>$name</cell>
      		<cell>$description</cell>
      		<cell>$key</cell>
      		<cell>$chanmode</cell>
				</row>
EOH;

			echo($html);
		}
	}
}


$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
