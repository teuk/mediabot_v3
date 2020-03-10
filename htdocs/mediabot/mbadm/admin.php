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
    <title>Administration</title>
    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
		
		<script>
			
			function doOnLoad() {
				var adminToolbar = new dhtmlXToolbarObject("myAdminToolbar");
  			adminToolbar.setIconsPath("codebase/imgs/");
  			adminToolbar.addText("adminToolbarTitle1", 0, "<b>Administration : <?php echo PORTAL_NAME ?></b>");
  			adminToolbar.addSeparator("adminToolbarSep1", 1);
  			
  			// gridStatusContainer init
				var gridStatusContainer = new dhtmlXGridObject('myGridStatusContainer');
				gridStatusContainer.setHeader("User,PID,PPID,C,STIME,TTY,TIME,CMD");
				gridStatusContainer.setInitWidths("100,50,50,50,100,100,100,400");
				gridStatusContainer.setColAlign("left,left,left,left,left,left,lest,left");
				gridStatusContainer.enableAutoHeight(true,800,true);
				gridStatusContainer.init();
				gridStatusContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro,ro");
				gridStatusContainer.load("xml/status.xml.php");
			}
			
		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainAdminContainer" style="width: 100%; height: 820px;" />
		<div id="myAdminToolbar" style="width: 100%;"></div>
		<div id="myGridStatusContainer"></div>
	</div>
<br>
</body>
</html>
