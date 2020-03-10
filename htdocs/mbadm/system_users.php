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
    <title>Utilisateurs</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">

		<script>
			function doOnLoad() {
				// Toolbar init
  			var usersToolbar = new dhtmlXToolbarObject("myUsersToolbar");
  			usersToolbar.setIconsPath("dhtmlxToolbar/codebase/imgs/");
  			usersToolbar.addText("usersToolbarTitle1", 0, "<b>Utilisateurs : <?php $hostname = exec('uname -n'); echo $hostname ?></b>");
  			usersToolbar.addSeparator("usersToolbarSep1", 1);
				
				// gridUsersContainer init
				var gridUsersContainer = new dhtmlXGridObject('mygridUsersContainer');
				gridUsersContainer.setImagePath("dhtmlxGrid/codebase/imgs/");
				gridUsersContainer.setHeader("User,UID,GID,Comment,Home Directory,Shell");
				gridUsersContainer.setInitWidths("150,50,50,300,200,200");
				gridUsersContainer.setColAlign("left,left,left,left,left,left");
				gridUsersContainer.enableAutoHeight(true,700,true);
				gridUsersContainer.init();
				gridUsersContainer.setColTypes("ed,ro,ro,ro,ro,ro");
				gridUsersContainer.load("xml/systemUsers.xml.php");
			}

		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainUsersContainer" style="width: 100%; height: 820px;" />
		<div id="myUsersToolbar" style="width: 100%;"></div>
		<div id="mygridUsersContainer"></div>
	</div>
<br>
</body>
</html>