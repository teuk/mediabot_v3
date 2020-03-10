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
		
		<script>
			
			function doOnLoad() {
				var mediabotToolbar = new dhtmlXToolbarObject("myMediabotToolbar");
  			mediabotToolbar.setIconsPath("codebase/imgs/");
  			mediabotToolbar.addText("mediabotToolbarTitle1", 0, "<b>Mediabot</b>");
  			mediabotToolbar.addSeparator("mediabotToolbarSep1", 1);
			}
			
		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainMediabotContainer" style="width: 100%; height: 820px;" />
		<div id="myMediabotToolbar" style="width: 100%;"></div>
	</div>
</body>
</html>
