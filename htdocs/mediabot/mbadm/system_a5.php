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
    <title>Système</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
				
		<script>
			var processTreeBox;
			
			function doOnLoad() {

			  processTreeBox = new dhtmlXTreeObject("myProcessTreeBox","100%","100%",0);
				//processTreeBox.setSkin("dhx_skyblue");
				//processTreeBox.setImagePath("dhtmlxTree/codebase/imgs/csh_bluebooks/");
				//processTreeBox.attachEvent("onSelect",selectConsoleItem);
				//processTreeBox.attachEvent("onClick",selectConsoleItem);
				
				processTreeBox.load("xml/system_a5.xml.php");
			}
		</script>
</head>
<body onload="doOnLoad()">
<div id="myProcessTreeBoxContainer">
	<div id="myProcessTreeBox" style="position:absolute; width:100%; height:100%;"></div>
</div>
<br>
</body>
</html>