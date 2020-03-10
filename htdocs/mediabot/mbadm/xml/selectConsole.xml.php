<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth_xml.php');
	require_once('includes/functions/dbConnect.php');
	require_once('includes/auth.php');
	
	// Check Radio Status
	function getConsoleURLXML($link) {
		$url = "about:blank";
		//Create query
		$consoleUrlQuery = "SELECT * FROM CONSOLE WHERE id_console=" . $_POST['id_console'];
		
		$result=mysqli_query($link,$consoleUrlQuery);
	
		if($result) {
			if($result->num_rows >= 1) {
				if ($consoleUrl = mysqli_fetch_assoc($result)) {
					$id_console = $consoleUrl["id_console"];
					$url = $consoleUrl["url"];
				}
				mysqli_free_result($result);
			}
			else {
				die ("No connection found in database");
			}
		}
		else {
			die ("No url found in database");
		}
	
		return $url;
		
	}

	header('Content-type: text/xml');
	
$consoleURLFromXML = getConsoleURLXML($link);
$consoleURLFromXML = htmlentities($consoleURLFromXML);
//$consoleURLFromXML = stripInvalidXml($consoleURLFromXML);
$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
	<consoleurl>$consoleURLFromXML</consoleurl>
EOH;

	echo ($html);

?>