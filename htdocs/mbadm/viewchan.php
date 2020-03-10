<?php
	require_once('includes/conf/config.php');
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = LEVEL_USER;
	require_once('includes/auth.php');
	require_once('includes/functions/dbConnect.php');
	
	$id_channel = $_GET['id_channel'];
	$id_user = $_SESSION['SESS_MEMBER_ID'];
	
	$userLevelQuery = "SELECT level FROM USER_CHANNEL WHERE id_user=$id_user";
	
	$userLevelResult=mysqli_query($link,$userLevelQuery);
	if($userLevelResult) {
		if($userLevelResult->num_rows >= 1) {
			if ($userLevelFields = mysqli_fetch_assoc($userLevelResult)) {
				$level = $userLevelFields["level"];
			}
		}
		else {
			header("Location: profile.php");
		}
	}
	else {
		error_log("SQL Query : $userLevelQuery");
	}
	
	$channelQuery = "SELECT * FROM CHANNEL WHERE id_channel=$id_channel";

	$channelResult=mysqli_query($link,$channelQuery);
	if($channelResult) {
		if($channelResult->num_rows >= 1) {
			if ($channelFields = mysqli_fetch_assoc($channelResult)) {
				$channel = $channelFields["name"];
			}
		}
		else {
			header("Location: profile.php");
		}
	}
	else {
		error_log("SQL Query : $channelQuery");
	}
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title>Information sur le channel</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
		
		<style>
			
			#myUsersToolbar {
				
			}
			
			#mygridChannelContainer {
				
			}
			
			#myUsersToolbar {
				
			}
			
			#mygridUsersChannelContainer {
				
			}
			
		</style>
		<script>
			function doOnLoad() {
				// Toolbar init
  			var channelToolbar = new dhtmlXToolbarObject("myChannelToolbar");
  			channelToolbar.setIconsPath("codebase/imgs/");
  			channelToolbar.addText("channelToolbarTitle1", 0, "<b>Information sur le channel <?php echo $channel ?></b>");
  			channelToolbar.addSeparator("channelToolbarSep1", 1);
				
				// gridChannelContainer init
				var gridChannelContainer = new dhtmlXGridObject('mygridChannelContainer');
				gridChannelContainer.setHeader("Channel ID,Name,Description,Key,Chanmode");
				gridChannelContainer.setInitWidths("70,200,300,150,*");
				gridChannelContainer.setColAlign("left,left,left,left,left");
				gridChannelContainer.enableAutoHeight(true,800,true);
				gridChannelContainer.init();
				gridChannelContainer.setColTypes("ro,ro,ro,ro,ro");
				gridChannelContainer.load("xml/channelInfos.xml.php?id_channel=<?php echo $id_channel ?>");
				
				// Toolbar init
  			var channelUsersToolbar = new dhtmlXToolbarObject("myUsersChannelToolbar");
  			channelUsersToolbar.setIconsPath("codebase/imgs/");
  			channelUsersToolbar.addText("channelUsersToolbarTitle1", 0, "<b>Information sur les utilisateurs</b>");
  			channelUsersToolbar.addSeparator("channelUsersToolbarSep1", 1);
  			<?php
  				if ( $level >= 400 ) {
  					
$html = <<< EOH
  			channelUsersToolbar.addButton("adduser", 2, "Ajouter un utlisateur sur ce channel", "add-user-icon.png", null);
  			channelUsersToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "adduser" ) {
							window.location.replace("adduserchan.php?id_channel=<?php echo $id_channel; ?>");
						}
					}
				);
EOH;

					echo($html);

					}
				?>
  			
  			// gridUsersChannelContainer init
				var gridUsersChannelContainer = new dhtmlXGridObject('mygridUsersChannelContainer');
				gridUsersChannelContainer.setHeader("User ID,Nickname,Channel Level,Automode,X Username,Info 1,Info 2");
				gridUsersChannelContainer.setInitWidths("50,150,100,150,150,150*");
				gridUsersChannelContainer.setColAlign("left,left,left,left,left,left,left");
				gridUsersChannelContainer.enableAutoHeight(true,800,true);
				gridUsersChannelContainer.init();
				gridUsersChannelContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro");
				gridUsersChannelContainer.load("xml/userChannelInfos.xml.php?id_channel=<?php echo $id_channel ?>");
				
				// Toolbar init
  			var channelLogsToolbar = new dhtmlXToolbarObject("myChannelLogsToolbar");
  			channelLogsToolbar.setIconsPath("codebase/imgs/");
  			channelLogsToolbar.addText("channelLogsToolbarTitle1", 0, "<b>Logs du channel <?php echo $channel ?></b>");
  			//channelLogsToolbar.addSeparator("channelLogsToolbarSep1", 1);
  			
  			// gridLogsChannelContainer init
				var gridLogsChannelContainer = new dhtmlXGridObject('mygridLogsChannelContainer');
				gridLogsChannelContainer.setHeader("Date / Heure,Évènement,Nick,Hostmask,Texte");
				gridLogsChannelContainer.setInitWidths("150,100,150,300,*");
				gridLogsChannelContainer.setColAlign("left,left,left,left,left");
				gridLogsChannelContainer.enableAutoHeight(true,800,true);
				gridLogsChannelContainer.init();
				gridLogsChannelContainer.setColTypes("ro,ro,ro,ro,ro");
				gridLogsChannelContainer.load("xml/logsChannelInfos.xml.php?id_channel=<?php echo $id_channel; ?>");
				
			}

		</script>
		
</head>
<body onload="doOnLoad()">
		<div id="mainChannelContainter">
			<div id="myChannelToolbar"></div>
			<div id="mygridChannelContainer"></div>
		</div>
	<div id="mainUsersChannelContainer">
		<div id="myUsersChannelToolbar"></div>
		<div id="mygridUsersChannelContainer"></div>
	</div>
	<!--
	<div id="mainLogsChannelContainer">
		<div id="myChannelLogsToolbar"></div>
		<div id="mygridLogsChannelContainer"></div>
	</div>
	-->
<br>
</body>
</html>