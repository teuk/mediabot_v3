<?php
	require_once('includes/conf/config.php');
	require_once('includes/functions/dbConnect.php');
	require_once('includes/functions/commonFunctions.php');
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

$id_public_commands_category = $_GET['id_public_commands_category'];

mysqli_query($link,"SET NAMES 'utf8'");
mysqli_query($link,"SET CHARACTER SET utf8");
mysqli_query($link,"SET COLLATION_CONNECTOIN = 'utf8_general_ci'");

$usersQuery = "SELECT * FROM PUBLIC_COMMANDS WHERE id_public_commands_category=$id_public_commands_category ORDER by command";

$usersResult=mysqli_query($link,$usersQuery);
if($usersResult) {
	if($usersResult->num_rows >= 1) {
		$usersCellId = 0;
		while ($usersFields = mysqli_fetch_assoc($usersResult)) {
			
			$command = "." . htmlspecialchars($usersFields["command"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			$description = htmlspecialchars($usersFields["description"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			//$action = _convert($usersFields["action"]);
			$action = htmlspecialchars($usersFields["action"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
			$action = preg_replace("/ACTION %c/","/me",$action);
			$action = preg_replace("/PRIVMSG %c/","",$action);
			$action = preg_replace("/%n/","nickname",$action);

$html = <<< EOH
      	<row id="$usersCellId">
      		<cell>$command</cell>
      		<cell>$description</cell>
      		<cell>$action</cell>
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
