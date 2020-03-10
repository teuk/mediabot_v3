<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth_xml.php');
	require_once('includes/functions/commonFunctions.php');
	require_once('includes/functions/dbConnect.php');
	
	function addSubTree($link,$current_id_console) {
		
	  $childQuery = "SELECT * FROM CONSOLE WHERE level >= " . $_SESSION['SESS_MEMBER_LEVEL'] . " AND id_parent=" . $current_id_console . " ORDER BY position";
	  //error_log($childQuery);
	  $childResult=mysqli_query($link,$childQuery);
	  if($childResult) {
			if($childResult->num_rows >= 1) {
				while ($consoleChildFields = mysqli_fetch_assoc($childResult)) {
					$id_console_child = $consoleChildFields["id_console"];
					$description_child = htmlspecialchars($consoleChildFields["description"], ENT_QUOTES | ENT_XML1);
					
					$url_child = $consoleChildFields["url"];
					$html = <<< EOH
					<item text="$description_child" id="$id_console_child" open="yes">
EOH;

					echo($html);
					
					addSubTree($link,$id_console_child);
					
					$html = <<< EOH
					</item>
EOH;

					echo($html);
				}
			}
			mysqli_free_result($childResult);
		}
	  return TRUE;
	}
	
	$consoleQuery = "SELECT * FROM CONSOLE WHERE level >= " . $_SESSION['SESS_MEMBER_LEVEL'] . " AND id_parent IS NULL ORDER BY position";
	//error_log($consoleQuery);
	$result=mysqli_query($link,$consoleQuery);
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<tree id="0">
EOH;

echo ($html);

if($result) {
		if($result->num_rows >= 1) {
		$i = 0;
		while ($consoleFields = mysqli_fetch_assoc($result)) {
			$id_console = $consoleFields["id_console"];
			$description = htmlspecialchars($consoleFields["description"], ENT_QUOTES | ENT_XML1);
			$url = $consoleFields["url"];
			
			// HINT text="Books" id="books" open="1" im0="tombs.gif" im1="tombs.gif" im2="iconSafe.gif" call="1" select="1">
   		$html = <<< EOH
   		<item text="$description" id="$id_console" open="yes" 
EOH;

   		echo($html);
   		
   		if ( $i == 0 ) {
   			echo "select=\"1\"";
   		}
   		$html = <<< EOH
>
EOH;

		echo($html);
		
		addSubTree($link,$id_console);
		
		$html = <<< EOH

</item>
EOH;

			echo($html);
   		$i++;
		}

		mysqli_free_result($result);

		}
		else {
			//die ("No console entry");
		}

}	

$html = <<< EOH
</tree>
EOH;

echo ($html);
?>
