<?php
	require_once('../includes/conf/config.php');
	
	$nick   = "mb";
	$server = "ix1.undernet.org";
	$room   = "quebec";
 	$uri = "https://widget.mibbit.com/" .
	"?nick=" . $nick . "_%3F%3F" . // each %3F(=?) will be replaced by a random digit 
	"&customprompt=Welcome%20to%20$server/$room" .
	"&customloading=maybe%20you%20need%20to%20close%20other%20Mibbit%20windows%20first..." .
	"&settings=c76462e5055bace06e32d325963b39f2"; // etc.
 	if (!empty($room))    {$uri .= '&channel=%23' . $room;}  
 	if (!empty($server )) {$uri .= '&server='     . $server;}

?>
<!DOCTYPE html>
<html lang="fr-FR">
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
	<title><?php echo PORTAL_NAME ?> - IRC</title>
	<link rel="icon" type="image/png" href="favicon.png">
	
	<!-- dhtmlx js functions -->
	<script type="text/javascript" src="../codebase/dhtmlx.js"></script>

	<!-- dhtmlx css -->
	<link rel="stylesheet" type="text/css" href="../codebase/dhtmlx.css">
	
	<script>
		
		function doOnLoad() {
				// Toolbar init
				var mainToolbar = new dhtmlXToolbarObject("mainToolbarContainer");
				mainToolbar.setIconsPath("../codebase/imgs/");
				mainToolbar.addText("titrePage", 0, "<b><?php echo PORTAL_NAME ?></b>");
				mainToolbar.addSeparator("sep1", 1);
				mainToolbar.addText("titrePage", 2, "Nous rejoindre sur IRC");
		}
		
	</script>
</head>
<body onload="doOnLoad()">
		<div id="mainToolbarContainer"></div>
		<div id="mibbitContainer">
			<iframe  src="<?PHP echo $uri; ?>" frameborder="0" width="97%" height="550">
			 [Your user agent does not support frames or is currently configured
			 not to display frames. However, you may want to open the
			 <A href="<?PHP echo $uri; ?>"
			 target="_blank"> chat in a new browser window ...</A>]
			</iframe>
		</div>
</body>

</html>

