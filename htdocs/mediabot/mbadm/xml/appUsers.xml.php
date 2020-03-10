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

$usersQuery = "SELECT * FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level ORDER BY level";

$usersResult=mysqli_query($link,$usersQuery);
if($usersResult) {
	if($usersResult->num_rows >= 1) {
		$usersCellId = 0;
		while ($usersFields = mysqli_fetch_assoc($usersResult)) {
			$id_user = $usersFields["id_user"];
			$username = htmlspecialchars($usersFields["username"], ENT_QUOTES);
			$nickname = htmlspecialchars($usersFields["nickname"], ENT_QUOTES);
			$hostmasks = htmlspecialchars($usersFields["hostmasks"], ENT_QUOTES);
			$level = $usersFields["level"];
			$description = htmlspecialchars($usersFields["description"], ENT_QUOTES);
			$info1 = htmlspecialchars($usersFields["info1"], ENT_QUOTES);
			$info2 = htmlspecialchars($usersFields["info2"], ENT_QUOTES);
			$password = htmlspecialchars($usersFields["password"], ENT_QUOTES);
			$boPassword = 0;
			if ( isset($password) && ( $password != "" ) ) {
				$boPassword = 1;
			}

$html = <<< EOH
      	<row id="$id_user">
      		<cell>$id_user</cell>
      		<cell>$nickname</cell>
      		<cell>$hostmasks</cell>
      		<cell>$username</cell>
      		<cell>$level</cell>
      		<cell>$description</cell>
      		<cell>$info1</cell>
      		<cell>$info2</cell>
      		<cell>$boPassword</cell>
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
