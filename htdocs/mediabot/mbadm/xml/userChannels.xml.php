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

$id_user = $_SESSION['SESS_MEMBER_ID'];

$usersQuery = "SELECT * FROM CHANNEL,USER_CHANNEL WHERE CHANNEL.id_channel=USER_CHANNEL.id_channel AND USER_CHANNEL.id_user=$id_user ORDER BY name";

$usersResult=mysqli_query($link,$usersQuery);
if($usersResult) {
	if($usersResult->num_rows >= 1) {
		$usersCellId = 0;
		while ($usersFields = mysqli_fetch_assoc($usersResult)) {
			$id_user = $usersFields["id_user"];
			$id_channel = $usersFields["id_channel"];
			$name = htmlspecialchars($usersFields["name"], ENT_QUOTES);
			$level = $usersFields["level"];
			$greet = htmlspecialchars($usersFields["greet"], ENT_QUOTES);
			$automode = htmlspecialchars($usersFields["automode"], ENT_QUOTES);

$html = <<< EOH
      	<row id="$id_channel">
      		<cell>$name</cell>
      		<cell>$level</cell>
      		<cell>$greet</cell>
      		<cell>$automode</cell>
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
