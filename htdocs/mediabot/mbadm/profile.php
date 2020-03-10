<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title>Informations utilisateur</title>
    
    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>
	
		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
    
    
		<script>
			function doOnLoad() {
				// mainLocalSystemToolbar init
  			var infoUserToolbar = new dhtmlXToolbarObject("myInfoUserToolbar");
  			infoUserToolbar.setIconsPath("codebase/imgs/");
  			infoUserToolbar.addText("infoUserToolbar1", 0, "<b>Informations sessions utilisateur</b>");
				
				// tportalUserContainer init
				var tportalUserContainer = new dhtmlXGridObject('mytportalUserContainer');
				tportalUserContainer.setImagePath("codebase/imgs/");
				tportalUserContainer.setHeader("Identifiant,Utilisateur,Niveau,Rôle");
				tportalUserContainer.setInitWidths("150,150,150,*");
				tportalUserContainer.setColAlign("left,left,Left,left");
				tportalUserContainer.enableAutoHeight(true,700,true);
				tportalUserContainer.init();
				tportalUserContainer.setColTypes("ro,ro,ro,ro");
				tportalUserContainer.load("xml/userInfo.xml.php");
				
				// mainLocalSystemToolbar init
  			var infoUserDbToolbar = new dhtmlXToolbarObject("myInfoUserDbToolbar");
  			infoUserDbToolbar.setIconsPath("codebase/imgs/");
  			infoUserDbToolbar.addText("infoUserDbToolbar1", 0, "<b>Informations utilisateur en base</b>");
				
				// gridUsersContainer init
				var gridUsersContainer = new dhtmlXGridObject('mygridUsersContainer');
				gridUsersContainer.setHeader("ID,Nickname,Hostmasks,Username,Niveau,Description,Info1,Info2,Pass");
				gridUsersContainer.setInitWidths("50,150,400,150,50,100,150,150,50");
				gridUsersContainer.setColAlign("left,left,left,left,left,left,lest,left,left");
				gridUsersContainer.enableAutoHeight(true,800,true);
				gridUsersContainer.init();
				gridUsersContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro,ro,ro");
				gridUsersContainer.load("xml/userInfoDb.xml.php");
				
				// mainLocalSystemToolbar init
  			var infoUserChannels = new dhtmlXToolbarObject("myInfoUserChannels");
  			infoUserChannels.setIconsPath("codebase/imgs/");
  			infoUserChannels.addText("infoUserChannels1", 0, "<b>Channels</b>");
				infoUserChannels.addSeparator("infoUserChannelsSep1", 1);
  			infoUserChannels.addText("infoUserChannels2", 2, "Double-click pour voir les détails d'un channel");
  			
  			// gridUserChannelContainer init
				var gridUserChannelContainer = new dhtmlXGridObject('mygridUserChannelContainer');
				gridUserChannelContainer.setHeader("Channel,Level,Greet,Automode");
				gridUserChannelContainer.setInitWidths("150,100,400,*");
				gridUserChannelContainer.setColAlign("left,left,left,left");
				gridUserChannelContainer.enableAutoHeight(true,800,true);
				gridUserChannelContainer.init();
				gridUserChannelContainer.setColTypes("ro,ro,ro,ro");
				gridUserChannelContainer.load("xml/userChannels.xml.php");
				gridUserChannelContainer.attachEvent("onRowDblClicked", function(rId,cInd){
					window.location.replace("viewchan.php?id_channel="+rId);
				});
				
			}

		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="myInfoUserToolbar"></div>
	<div id="mytportalUserContainer" style="overflow:hidden"></div>
	<div id="myInfoUserDbToolbar"></div>
	<div id="mygridUsersContainer" style="overflow:hidden"></div>
	<div id="myInfoUserChannels"></div>
	<div id="mygridUserChannelContainer" style="overflow:hidden"></div>
<br>
</body>
</html>