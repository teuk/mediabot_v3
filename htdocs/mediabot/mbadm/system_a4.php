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
    <title>Process</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">

		<script>
			function doOnLoad() {
	
				// gridProcessInfoContainer init
				var gridProcessInfoContainer = new dhtmlXGridObject('mygridProcessInfoContainer');
				//gridProcessInfoContainer.setImagePath("dhtmlxGrid/codebase/imgs/");
				////UID        PID  PPID  C STIME TTY          TIME CMD
				gridProcessInfoContainer.setHeader("UID,PID,PPID,CMD,STIME,TTY,TIME");
				gridProcessInfoContainer.setInitWidths("100,75,75,300,75,75,75");
				gridProcessInfoContainer.setColAlign("left,left,left,left,left,left,left");
				gridProcessInfoContainer.enableAutoHeight(true,700,true);
				gridProcessInfoContainer.init();
				gridProcessInfoContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro");
				gridProcessInfoContainer.load("xml/system_a4.xml.php");
			}
	
		</script>
</head>
<body onload="doOnLoad()">
<div id="mygridGlobalProcessInfoContainer">
	<div id="mygridProcessInfoContainer"></div>
</div>
<br>
</body>
</html>