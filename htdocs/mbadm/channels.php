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
  			usersToolbar.setIconsPath("codebase/imgs/");
  			usersToolbar.addText("usersToolbarTitle1", 0, "<b>Channels : <?php echo PORTAL_NAME ?></b>");
  			usersToolbar.addSeparator("usersToolbarSep1", 1);
  			usersToolbar.addText("usersToolbarTitle2", 2, "Double-click pour éditer un channel");
  			usersToolbar.addSeparator("usersToolbarSep2", 3);
  			usersToolbar.addButton("addchannel", 4, "Ajouter un channel", "add.png", null);
  			usersToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "addchannel" ) {
							window.location.replace("addchannel.php");
						}
					}
				);
				
				// gridUsersContainer init
				var gridUsersContainer = new dhtmlXGridObject('mygridUsersContainer');
				gridUsersContainer.setHeader("ID,Channel,Description,Key,Modes,Auto join");
				gridUsersContainer.setInitWidths("50,150,200,150,200,100");
				gridUsersContainer.setColAlign("left,left,left,lest,left,left");
				gridUsersContainer.enableAutoHeight(true,700,true);
				gridUsersContainer.init();
				gridUsersContainer.setColTypes("ro,ro,ro,ro,ro,ro");
				gridUsersContainer.load("xml/channels.xml.php");
				gridUsersContainer.attachEvent("onRowDblClicked", function(rId,cInd){
					window.location.replace("viewchan.php?id_channel="+rId);
				});
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