<?php
	require_once('includes/conf/config.php');
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = LEVEL_MASTER;
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
  			usersToolbar.addText("usersToolbarTitle1", 0, "<b>Utilisateurs : <?php echo PORTAL_NAME ?></b>");
  			usersToolbar.addSeparator("usersToolbarSep1", 1);
  			usersToolbar.addButton("adduser", 2, "Ajouter un utilisateur", "add-user-icon.png", null);
  			usersToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "adduser" ) {
							window.location.replace("adduser.php");
						}
					}
				);
				
				// gridUsersContainer init
				var gridUsersContainer = new dhtmlXGridObject('mygridUsersContainer');
				gridUsersContainer.setHeader("ID,Nickname,Hostmasks,Username,Niveau,Description,Info1,Info2,Pass");
				gridUsersContainer.setInitWidths("50,150,400,150,50,100,150,150,50");
				gridUsersContainer.setColAlign("left,left,left,left,left,left,lest,left,left");
				gridUsersContainer.enableAutoHeight(true,800,true);
				gridUsersContainer.init();
				gridUsersContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro,ro,ro");
				gridUsersContainer.load("xml/appUsers.xml.php");
				gridUsersContainer.attachEvent("onRowDblClicked", function(rId,cInd){
					window.location.replace("viewuser.php?id_user="+rId);
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