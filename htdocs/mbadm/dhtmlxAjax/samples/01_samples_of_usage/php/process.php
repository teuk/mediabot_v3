<?php
	if ( stristr($_SERVER["HTTP_ACCEPT"],"application/xhtml+xml") ) {
  		header("Content-type: application/xhtml+xml"); } else {
  		header("Content-type: text/xml");
	}
	echo("<?xml version=\"1.0\" encoding=\"iso-8859-1\"?>\n"); 

	echo "<scopes>\n";
		echo "<POST>\n";
			$pKeys = array_keys($_POST);
			for($i=0;$i<count($pKeys);$i++){
				echo "<param name='".$pKeys[$i]."'>".$_POST[$pKeys[$i]]."</param>\n";
			}
		echo "</POST>\n";
		echo "<GET>\n";
			$gKeys = array_keys($_GET);
			for($i=0;$i<count($gKeys);$i++){
				echo "<param name='".$gKeys[$i]."'>".$_GET[$gKeys[$i]]."</param>\n";
			}
		echo "</GET>\n";
	echo "</scopes>";
?>