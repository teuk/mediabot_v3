<?php
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = 1;
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title>Ajouter un utilisateur</title>
    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
		
		<script>
			//var tabbar;
			
			function doOnLoad() {
				
			}
			
		</script>
		
</head>
<body onload="doOnLoad()">
<br>
</body>
</html>
