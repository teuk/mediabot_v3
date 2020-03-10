<?php
	require_once('includes/conf/config.php');
	require_once('includes/functions/commonFunctions.php');
	require_once('includes/auth.php');
	
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title><?php echo PORTAL_NAME; ?></title>
    
    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>
	
		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
			
		<!-- dhtmlxAjax js -->
		<script type="text/javascript" src="dhtmlxAjax/codebase/dhtmlxcommon.js"></script>

		<script>
			
			var dhxLayout;
			var mainTree;
			
			function doOnLoad() {
				// Toolbar init
  			var mainToolbar = new dhtmlXToolbarObject("mainToolbarContainer");
  			mainToolbar.setIconsPath("codebase/imgs/");
  			mainToolbar.addText("titrePage", 0, "<b>Administration <?php echo PORTAL_NAME ?></b>");
  			mainToolbar.addSeparator("sep1", 1);
  			mainToolbar.addText("connectionInfo", 2, "Vous êtes connecté en tant que : <?php echo $_SESSION['SESS_MEMBER_LOGIN'] ?> (<?php echo $_SESSION['SESS_MEMBER_LEVEL_DESC'] ?>)");
  			mainToolbar.addSeparator("sep2", 4);
  			mainToolbar.addButton("settings", 5, "Paramètres", "settings.png", null);
  			mainToolbar.addSeparator("sep3", 6);
  			mainToolbar.addButton("logout", 7, "Déconnexion", "logout.jpg", null);
				mainToolbar.attachEvent("onClick",
					function(id) {
						if ( id == "logout" ) {
							window.location.replace("logout.php");
						}
						else if ( id == "settings") {
							alert("TBD my id is " + id);
						}
						
					}
				);
				
				dhxLayout = new dhtmlXLayoutObject("mainLayoutContainer", "2U");
				dhxLayout.cells("a").setWidth(250);
				dhxLayout.cells("a").setText("Navigation");
				dhxLayout.cells("b").hideHeader();
				mainTree = dhxLayout.cells("a").attachTree("0");
				mainTree.setImagePath("codebase/skins/skyblue/imgs/dhxtree_skyblue/");
				mainTree.load("xml/mainTree.xml.php");
				mainTree.attachEvent("onSelect",selectConsoleItem);
				mainTree.attachEvent("onClick",selectConsoleItem);
			}
			
			function selectConsoleItem(consoleId) {
				selectConsoleLoader = dhtmlxAjax.postSync("xml/selectConsole.xml.php","id_console=" + consoleId);
				selectConsoleCheck = checkConsoleXMLRequest(selectConsoleLoader,consoleId);
				dhxLayout.cells("b").attachURL(selectConsoleCheck);
				return true;
			}
			
			function checkConsoleXMLRequest (loader,consoleId) {
				if (loader.xmlDoc.responseXML != null) {
					xmlUrlConsoleNode = loader.xmlDoc.responseXML.getElementsByTagName("consoleurl" ).item(0);
					if ( xmlUrlConsoleNode == null ) {
						xmlAuthConsoleNode = loader.xmlDoc.responseXML.getElementsByTagName("authentication" ).item(0);
						consoleAUTHFromXMLValue = xmlAuthConsoleNode.firstChild.nodeValue;
						if ( consoleAUTHFromXMLValue == 0 ) {
							document.location = "index.php";
						}
						else {
							<?php
								if ( XML_DEBUG ) {
									echo("alert(\"Error parsing XML : xml/selectConsole.xml.php POST id_console=\" + consoleId);");
								}
							?>
						}
					}
					else {
						consoleURLFromXMLValue = xmlUrlConsoleNode.firstChild.nodeValue;
	    			return consoleURLFromXMLValue;
	    		}
	    	}
	    	else {
					<?php
						if ( XML_DEBUG ) {
							echo("alert(\"Invalid XML : xml/selectConsole.xml.php POST id_console=\" + consoleId);");
						}
					?>
	    	}
			}
			
		</script>
		<style>
	    html, body {
	        width: 100%;
	        height: 100%;
	        margin: 0px;
	        overflow: hidden;
	    }
		</style>
		
</head>
<body onload="doOnLoad()">
	
	<div id="mainContainerAdmin" style="position:absolute; width:100%; height:100%;">
	
		<div id="mainToolbarContainer"></div>
		
		<div id="mainLayoutContainer" style="position:absolute; width:100%; height:100%;">a</div>
	
	</div>
	
</body>
</html>