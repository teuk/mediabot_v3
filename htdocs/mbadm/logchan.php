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
		<link rel="stylesheet" type="text/css" href="skins/web/dhtmlx.css"/>
		
		<script>
			function doOnLoad() {
				// Toolbar init
  			var channelLogsToolbar = new dhtmlXToolbarObject("myChannelLogsToolbar");
  			channelLogsToolbar.setIconsPath("codebase/imgs/");
  			channelLogsToolbar.addText("channelLogsToolbarTitle1", 0, "<b>Logs du channel <?php echo $channel ?></b>");
  			channelLogsToolbar.addSeparator("channelLogsToolbarSep1", 1);
  			channelLogsToolbar.addButton("showrow", 2, "Voir la fin du log et rafraîchir", "bottom-arrow.png", null);
  			channelLogsToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "showrow" ) {
							gridLogsChannelContainer.clearAll();
							gridLogsChannelContainer.load("xml/logsChannelInfos.xml.php?id_channel=<?php echo $id_channel; ?>",function() {
			  				gridLogsChannelContainer.showRow("channelLine" + (gridLogsChannelContainer.getRowsNum() - 1));
			  			});
						}
					}
				);
				channelLogsToolbar.addSeparator("channelLogsToolbarSep2", 3);
				channelLogsToolbar.addText("channelLogsToolbarTitle2", 4, "<b>Entrez une date au format (dd/mm/YYYY)</b>");
				channelLogsToolbar.addInput("channelLogsInputDate", 5, "", 150);
				channelLogsToolbar.addButton("godate", 6, "Consulter", "", null);
  			channelLogsToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "godate" ) {
							alert(channelLogsToolbar);
						}
					}
				);
  			
  			// gridLogsChannelContainer init
				var gridLogsChannelContainer = new dhtmlXGridObject('mygridLogsChannelContainer');
				gridLogsChannelContainer.setImagePath("skins/web/imgs/dhxgrid_web/");
				gridLogsChannelContainer.setHeader("Date,Texte");
				gridLogsChannelContainer.setInitWidths("150*");
				gridLogsChannelContainer.setColAlign("left,left");
				gridLogsChannelContainer.enableAutoHeight(true,800,true);
				gridLogsChannelContainer.init();
				gridLogsChannelContainer.setColTypes("ro,ro");
				gridLogsChannelContainer.load("xml/logsChannelInfos.xml.php?id_channel=<?php echo $id_channel; ?>",function() {
  				gridLogsChannelContainer.showRow("channelLine" + (gridLogsChannelContainer.getRowsNum() - 1));
  			});
				
			}
		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainLogsChannelContainer">
		<div id="myChannelLogsToolbar"></div>
		<div id="mygridLogsChannelContainer"></div>
	</div>
<br>
</body>
</html>