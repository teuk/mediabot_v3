<?php
	//Start session if it does not exist
	if (session_status() == PHP_SESSION_NONE) {
    session_start();
	}
	
	//Check whether the session variable SESS_MEMBER_ID is present or not
	if(!isset($_SESSION['SESS_MEMBER_ID']) || (trim($_SESSION['SESS_MEMBER_ID']) == '')) {
		$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
	<authentication>0</authentication>
EOH;

		header('Content-type: text/xml');
		echo($html);
		exit();
	}
	
	if (isset($_SESSION['SESS_XML_LEVEL']) && ($_SESSION['SESS_MEMBER_LEVEL'] > $_SESSION['SESS_XML_LEVEL'])) {
		unset($_SESSION['SESS_XML_LEVEL']);
		$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<null></null>
EOH;

		header('Content-type: text/xml');
		echo($html);
		exit();
	}
?>
