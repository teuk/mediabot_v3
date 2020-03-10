<?php
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = 3;
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
		
		<style>
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
		</style>
		
		<script>
			
			function doOnLoad() {
				var radioToolbar = new dhtmlXToolbarObject("myRadioToolbar");
  			radioToolbar.setIconsPath("codebase/imgs/");
  			radioToolbar.addText("radioToolbarTitle1", 0, "<b>Radio</b>");
  			radioToolbar.addSeparator("radioToolbarSep1", 1);
  			
  			// currentSongGrid init
				currentSongGrid = new dhtmlXGridObject('mycurrentSongGrid');
				currentSongGrid.setImagePath("codebase/imgs/");
				currentSongGrid.setHeader("En ce moment");
				currentSongGrid.setInitWidths("*");
				currentSongGrid.setColAlign("left");
				currentSongGrid.enableAutoHeight(true,250,true);
				currentSongGrid.init();
				currentSongGrid.setColTypes("ro");
				currentSongGrid.load("xml/currentSong.xml.php");
				
				// currentRemainingGrid init
				currentRemainingGrid = new dhtmlXGridObject('mycurrentRemainingGrid');
				currentRemainingGrid.setImagePath("codebase/imgs/");
				currentRemainingGrid.setHeader("Temps restant");
				currentRemainingGrid.setInitWidths("*");
				currentRemainingGrid.setColAlign("left");
				currentRemainingGrid.enableAutoHeight(true,250,true);
				currentRemainingGrid.init();
				currentRemainingGrid.setColTypes("ro");
				currentRemainingGrid.load("xml/currentSongRemaining.xml.php");
			}
			
			function refreshTitle() {
				currentSongGrid.clearAll();
				currentSongGrid.setImagePath("codebase/imgs/");
				currentSongGrid.setHeader("En ce moment");
				currentSongGrid.setInitWidths("*");
				currentSongGrid.setColAlign("left");
				currentSongGrid.enableAutoHeight(true,250,true);
				currentSongGrid.init();
				currentSongGrid.setColTypes("ro");
				currentSongGrid.load("xml/currentSong.xml.php");
			}
			
			var current_metadata;
			var metadata;
			
			function getMetadata() {
			  var xhttp = new XMLHttpRequest();
			  xhttp.onreadystatechange = function() {
			    if (xhttp.readyState == 4 && xhttp.status == 200) {
			      getMetaDataAsync(xhttp);
			    }
			  };
			  xhttp.open("GET", "xml/metadata.xml.php", true);
			  xhttp.send();
			}
			
			function getMetadataOnLoad() {
			  var xhttp = new XMLHttpRequest();
			  xhttp.onreadystatechange = function() {
			    if (xhttp.readyState == 4 && xhttp.status == 200) {
			      getMetaDataAsyncOnload(xhttp);
			    }
			  };
			  xhttp.open("GET", "xml/metadata.xml.php", true);
			  xhttp.send();
			}
			
			function getMetaDataAsync(xml) {
			  var xmlDoc = xml.responseXML;
			  var x = xmlDoc.getElementsByTagName("metadata");
			  metadata = x[0].childNodes[0].nodeValue;
			  if ( current_metadata != metadata ) {
			  	//alert("metadata changed. current_metadata = " + current_metadata + " metadata = " + metadata);
			  	current_metadata = metadata;
			  	currentSongGrid.clearAll();
					currentSongGrid.setImagePath("codebase/imgs/");
					currentSongGrid.setHeader("Temps restant");
					currentSongGrid.setInitWidths("*");
					currentSongGrid.setColAlign("left");
					currentSongGrid.enableAutoHeight(true,250,true);
					currentSongGrid.init();
					currentSongGrid.setColTypes("ro");
					currentSongGrid.load("xml/currentSong.xml.php");
			  }
			}
			
			function getMetaDataAsyncOnload(xml) {
			  var xmlDoc = xml.responseXML;
			  var x = xmlDoc.getElementsByTagName("metadata");
			  metadata = x[0].childNodes[0].nodeValue;
			  current_metadata = metadata;
			}
			
			function getRemaining() {
				currentRemainingGrid.clearAll();
				currentRemainingGrid.setImagePath("codebase/imgs/");
				currentRemainingGrid.setHeader("Temps restant");
				currentRemainingGrid.setInitWidths("*");
				currentRemainingGrid.setColAlign("left");
				currentRemainingGrid.enableAutoHeight(true,250,true);
				currentRemainingGrid.init();
				currentRemainingGrid.setColTypes("ro");
				currentRemainingGrid.load("xml/currentSongRemaining.xml.php");
			}
			
			getMetadataOnLoad();
			setInterval(getMetadata, 30000);
			setInterval(getRemaining, 30000);
			
		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainRadioContainer" style="width: 100%; height: 820px;" />
		<div id="myRadioToolbar" style="width: 100%;"></div>
		<div id="mediabotPlayerContainer">
			<iframe src="jplayer/mediabot_player.php" width="438" height="150" frameborder="0" longdesc="Mediabot Radio Player" scrolling="no"></iframe>
		</div>
		<div id="currentSongContainer">
			<div id="mycurrentSongGrid" style="overflow:hidden"></div>
			<div id="mycurrentRemainingGrid" style="overflow:hidden"></div>
		</div>
	</div>
<br>
</body>
</html>
