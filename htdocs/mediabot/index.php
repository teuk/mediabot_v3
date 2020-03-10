<?php
	require_once('includes/conf/config.php');
	require_once('includes/functions/dbConnect.php');
?>
<!DOCTYPE html>
<html lang="fr-FR">
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
	<title><?php echo PORTAL_NAME ?></title>
	<link rel="icon" type="image/png" href="favicon.png">
	
	<style>
		
		#selectCatCommandsToolbarContainer {
			position: absolute;
			top: 60px;
			width: 100%;
		}
		
		#mediabotPlayerContainer {
			position: absolute;
			top: 60px;
		}
		
		#currentSongContainer {
			position: absolute;
			top: 69px;
			left: 225px;
			width: 600px;
		}
		
		body {background-color:black;}
	</style>
	
	<!-- dhtmlx js functions -->
	<script type="text/javascript" src="codebase/dhtmlx.js"></script>

	<!-- dhtmlx css -->
	<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
	
	<!-- dhtmlxAjax js 
	<script type="text/javascript" src="dhtmlxAjax/codebase/dhtmlxcommon.js"></script>
	-->
	<script>
		
		var categoryOpts;
<?php
	
	$countCategoryQuery = "SELECT COUNT(*) as nbCategory FROM PUBLIC_COMMANDS_CATEGORY";
	$result=mysqli_query($link,$countCategoryQuery);
	if($result) {
		if($result->num_rows >= 1) {
			if ($countNbCategory = mysqli_fetch_assoc($result)) {
				$nbCategory = $countNbCategory["nbCategory"];
			}
		}
	}
?>
		categoryOpts = Array(
<?php
			$channelQuery = "SELECT * FROM PUBLIC_COMMANDS_CATEGORY";
			$result=mysqli_query($link,$channelQuery);
      $arrayChannelsOpts = "";
			if($result) {
				if($result->num_rows >= 1) {
					$cptCountChannel = 0;
					while ($channels = mysqli_fetch_assoc($result)) {
						$id_public_commands_category = $channels["id_public_commands_category"];
						$description = htmlspecialchars($channels["description"], ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);
						
		    		$arrayChannelsOpts .= "Array('" . $id_public_commands_category . "', 'obj', '" . htmlspecialchars($description,ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED) . "', null)";
		    		$cptCountChannel++;
		    		if ( $cptCountChannel < $nbCategory ) {
		    			 $arrayChannelsOpts .= ",";
		    		}
		    	}
		    	echo $arrayChannelsOpts;
	    	}
	    }
?>
		
		);
	
		//Array.prototype.findIndex = function(value){
		//	var ctr = "";
		//	for (var i=0; i < this.length; i++) {
		//	// use === to check for Matches. ie., identical (===), ;
		//		if (this[i][0] == value) {
		//			return i;
		//		}
		//	}
		//	return ctr;
		//};
		
		//var currentSongGrid;
		
		function doOnLoad() {
			// Toolbar init
			var mainToolbar = new dhtmlXToolbarObject("mainToolbarContainer");
			mainToolbar.setIconsPath("codebase/imgs/");
			mainToolbar.addText("titrePage", 0, "<b><?php echo PORTAL_NAME ?></b>");
			mainToolbar.addSeparator("sep1", 1);
			mainToolbar.addButton("login", 2, "Administration", "login.png", null);
			mainToolbar.setItemToolTip("login", "Administration <?php echo PORTAL_NAME ?>");
			mainToolbar.attachEvent("onClick",
				function(id) {
					if ( id == "login" ) {
						window.location.replace("/mediabot/mbadm");
					}
				}
			);

			// currentSongGrid init
			//currentSongGrid = new dhtmlXGridObject('mycurrentSongGrid');
			//currentSongGrid.setImagePath("codebase/imgs/");
			//currentSongGrid.setHeader("En ce moment");
			//currentSongGrid.setInitWidths("*");
			//currentSongGrid.setColAlign("left");
			//currentSongGrid.enableAutoHeight(true,250,true);
			//currentSongGrid.init();
			//currentSongGrid.setColTypes("ro");
			//currentSongGrid.load("xml/currentSong.xml.php");
			
			// currentRemainingGrid init
			//currentRemainingGrid = new dhtmlXGridObject('mycurrentRemainingGrid');
			//currentRemainingGrid.setImagePath("codebase/imgs/");
			//currentRemainingGrid.setHeader("Temps restant");
			//currentRemainingGrid.setInitWidths("*");
			//currentRemainingGrid.setColAlign("left");
			//currentRemainingGrid.enableAutoHeight(true,250,true);
			//currentRemainingGrid.init();
			//currentRemainingGrid.setColTypes("ro");
			//currentRemainingGrid.load("xml/currentSongRemaining.xml.php");

			var selectCatCommandsToolbar = new dhtmlXToolbarObject("selectCatCommandsToolbar");
			selectCatCommandsToolbar.setIconsPath("codebase/imgs/");
			selectCatCommandsToolbar.addText("titreCategoryFromToolbar1", 0, "<b>Commandes publiques</b>");
			selectCatCommandsToolbar.addSeparator("sepCategoryFromToolbar1", 1);
			selectCatCommandsToolbar.addText("titreCategoryFromToolbar2", 2, "Pour les utiliser, tapez .commande sur le channel");
			selectCatCommandsToolbar.addSeparator("sepCategoryFromToolbar2", 3);
			selectCatCommandsToolbar.addText("titreCategoryFromToolbar3", 4, "Sélectionnez une catégorie");
			selectCatCommandsToolbar.addSeparator("sepCategoryFromToolbar3", 5);
			selectCatCommandsToolbar.addButtonSelect("selectCategoryFromToolbar", 6, "Général", categoryOpts);
			selectCatCommandsToolbar.attachEvent("onClick",
				function(selectChannel) {
					//alert("Sélection de l'utilisateur " + selectChannel);
					if ( selectChannel != "selectCategoryFromToolbar" ) {
						// TBD : Problème de refresh de la grid
						mbCommandsGrid.clearAll();
						mbCommandsGrid.setHeader("Commande,Description,Action");
						mbCommandsGrid.setInitWidths("150,200,*");
						mbCommandsGrid.setColAlign("left,left,left");
						mbCommandsGrid.enableAutoHeight(true,800,true);
						//mbCommandsGrid.setStyle("background-color:navy;color:white; font-weight:bold;", "background-color:black; color:white; font-face: 'Lucida Sans Unicode';","color:red;", "");
						mbCommandsGrid.init();
						mbCommandsGrid.setColTypes("ed,ro,ro");
						mbCommandsGrid.load("xml/commands.xml.php?id_public_commands_category=" +selectChannel);
						//mbCommandsGrid.attachEvent("onRowDblClicked", function(rId,cInd){
						//	alert("Ajout du média rId=" + rId + " cInd=" + cInd);
						//});
						//mbCommandsGrid.updateFromXML("xml/selectedUserMedia.xml.php?id_user=" + selectChannel);
						//channelToolbar.setItemText("currentSelectedUsetTextInToolbar", "<b>Utilisateur sélectionné&nbsp;:&nbsp;<font style=\"color : #7E1BE0;\">" + usersOpts[usersOpts.findIndex(selectChannel)][2] + "</b>");
						//userMediaCountLoaderById = dhtmlxAjax.getSync("xml/userMediaCount.xml.php?id_user=" + selectChannel);
						//userMediaCountCheckById = userMediaCountByIdXMLRequest(userMediaCountLoaderById);
						//channelToolbar.setItemText("selectUserFromToolbarMediaCountValue", "<font style=\"font-weight:bold; color:#7E1BE0;\">" + userMediaCountCheckById + "</font>");
					}
				}
			);
			
			var mbCommandsGrid = new dhtmlXGridObject('myCommandsGrid');
			mbCommandsGrid.setHeader("Commande,Description,Action");
			mbCommandsGrid.setInitWidths("150,200,*");
			mbCommandsGrid.setColAlign("left,left,left");
			mbCommandsGrid.enableAutoHeight(true,800,true);
			mbCommandsGrid.init();
			mbCommandsGrid.setColTypes("ed,ro,ro");
			mbCommandsGrid.load("xml/commands.xml.php?id_public_commands_category=1");
			
			//function refreshTitle() {
			//	currentSongGrid.clearAll();
			//	currentSongGrid.setImagePath("codebase/imgs/");
			//	currentSongGrid.setHeader("En ce moment");
			//	currentSongGrid.setInitWidths("*");
			//	currentSongGrid.setColAlign("left");
			//	currentSongGrid.enableAutoHeight(true,250,true);
			//	currentSongGrid.init();
			//	currentSongGrid.setColTypes("ro");
			//	currentSongGrid.load("xml/currentSong.xml.php");
			//}
			
			//var current_metadata;
			//var metadata;
			
			//function getMetadata() {
			//  var xhttp = new XMLHttpRequest();
			//  xhttp.onreadystatechange = function() {
			//    if (xhttp.readyState == 4 && xhttp.status == 200) {
			//      getMetaDataAsync(xhttp);
			//    }
			//  };
			//  xhttp.open("GET", "xml/metadata.xml.php", true);
			//  xhttp.send();
			//}
			
			//function getMetadataOnLoad() {
			//  var xhttp = new XMLHttpRequest();
			//  xhttp.onreadystatechange = function() {
			//    if (xhttp.readyState == 4 && xhttp.status == 200) {
			//      getMetaDataAsyncOnload(xhttp);
			//    }
			//  };
			//  xhttp.open("GET", "xml/metadata.xml.php", true);
			//  xhttp.send();
			//}
			
			//function getMetaDataAsync(xml) {
			//  var xmlDoc = xml.responseXML;
			//  var x = xmlDoc.getElementsByTagName("metadata");
			//  metadata = x[0].childNodes[0].nodeValue;
			//  if ( current_metadata != metadata ) {
			//  	//alert("metadata changed. current_metadata = " + current_metadata + " metadata = " + metadata);
			//  	current_metadata = metadata;
			//  	currentSongGrid.clearAll();
			//		currentSongGrid.setImagePath("codebase/imgs/");
			//		currentSongGrid.setHeader("En ce moment");
			//		currentSongGrid.setInitWidths("*");
			//		currentSongGrid.setColAlign("left");
			//		currentSongGrid.enableAutoHeight(true,250,true);
			//		currentSongGrid.init();
			//		currentSongGrid.setColTypes("ro");
			//		currentSongGrid.load("xml/currentSong.xml.php");
			//  }
			//}
			
			//function getMetaDataAsyncOnload(xml) {
			//  var xmlDoc = xml.responseXML;
			//  var x = xmlDoc.getElementsByTagName("metadata");
			//  metadata = x[0].childNodes[0].nodeValue;
			//  current_metadata = metadata;
			//}
			//
			//function getRemaining() {
			//	currentRemainingGrid.clearAll();
			//	currentRemainingGrid.setImagePath("codebase/imgs/");
			//	currentRemainingGrid.setHeader("Temps restant");
			//	currentRemainingGrid.setInitWidths("*");
			//	currentRemainingGrid.setColAlign("left");
			//	currentRemainingGrid.enableAutoHeight(true,250,true);
			//	currentRemainingGrid.init();
			//	currentRemainingGrid.setColTypes("ro");
			//	currentRemainingGrid.load("xml/currentSongRemaining.xml.php");
			//}
			//
			//getMetadataOnLoad();
			//setInterval(getMetadata, 30000);
			//setInterval(getRemaining, 30000);
			
		}
	</script>
</head>

<body onload="doOnLoad()">
	
		<div id="mainToolbarContainer"></div>
		<!--
		<div id="mediabotPlayerContainer">
			<iframe src="jplayer/mediabot_player.php" width="438" height="150" frameborder="0" longdesc="Mediabot Radio Player" scrolling="no"></iframe>
		</div>
		<div id="currentSongContainer">
			<div id="mycurrentSongGrid" style="overflow:hidden"></div>
			<div id="mycurrentRemainingGrid" style="overflow:hidden"></div>
		</div>
		-->
		<div id="selectCatCommandsToolbarContainer">
			<div id="selectCatCommandsToolbar"></div>
			<div id="myCommandsGrid"></div>
		</div>
</body>

</html>

