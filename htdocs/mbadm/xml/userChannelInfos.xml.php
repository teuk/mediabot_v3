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

$channelQuery = "SELECT * FROM USER,USER_CHANNEL WHERE USER.id_user=USER_CHANNEL.id_user AND USER_CHANNEL.id_channel=$id_channel ORDER BY level DESC";

$usersChannelResult=mysqli_query($link,$channelQuery);
if($usersChannelResult) {
	if($usersChannelResult->num_rows >= 1) {
		$usersCellId = 0;
		while ($usersChannelFields = mysqli_fetch_assoc($usersChannelResult)) {
			$id_user = $usersChannelFields["id_user"];
			$nickname = htmlspecialchars($usersChannelFields["nickname"], ENT_QUOTES);
			$level = $usersChannelFields["level"];
			$username = htmlspecialchars($usersChannelFields["username"], ENT_QUOTES);
			$info1 = htmlspecialchars($usersChannelFields["info1"], ENT_QUOTES);
			$info2 = htmlspecialchars($usersChannelFields["info2"], ENT_QUOTES);
			$automode = htmlspecialchars($usersChannelFields["automode"], ENT_QUOTES);

$html = <<< EOH
      	<row id="userChan$usersCellId">
      		<cell>$id_user</cell>
      		<cell>$nickname</cell>
      		<cell>$level</cell>
      		<cell>$automode</cell>
      		<cell>$username</cell>
      		<cell>$info1</cell>
      		<cell>$info2</cell>
				</row>
EOH;

			echo($html);
			$usersCellId++;
		}
	}
}


$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
