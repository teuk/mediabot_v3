<?php
	require_once('includes/conf/config.php');
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
  			var currentSongToolbar = new dhtmlXToolbarObject("myCurrentSongToolbar");
  			currentSongToolbar.setIconsPath("codebase/imgs/");
  			currentSongToolbar.addText("currentSongToolbar1", 0, "<b>En ce moment</b>");
				
				// currentSongGrid init
				var currentSongGrid = new dhtmlXGridObject('mycurrentSongGrid');
				currentSongGrid.setImagePath("codebase/imgs/");
				currentSongGrid.setHeader("Artiste,Titre");
				currentSongGrid.setInitWidths("200,*");
				currentSongGrid.setColAlign("left,left");
				currentSongGrid.enableAutoHeight(true,150,true);
				currentSongGrid.init();
				currentSongGrid.setColTypes("ro,ro");
				currentSongGrid.load("xml/currentSong.xml.php");
			}

		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="myCurrentSongToolbar"></div>
	<div id="mycurrentSongGrid" style="overflow:hidden"></div>
<br>
</body>
</html>