<?php
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = 1;
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
	$unameExec = exec("uname -a");
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title>System</title>
    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
		
		<script>
			//var tabbar;
			
			function doOnLoad() {
				// mainLocalSystemToolbar init
  			mainLocalSystemToolbar = new dhtmlXToolbarObject("myMainLocalSystemToolbar");
  			mainLocalSystemToolbar.setIconsPath("codebase/skins/skyblue/imgs/dhxtoolbar_skyblue/");
  			mainLocalSystemToolbar.addText("homeTitleToolbar1", 0, "<b>Système : <?php echo $_SERVER['SERVER_NAME']; ?></b>&nbsp;");
  			mainLocalSystemToolbar.addSeparator("homeTitleToolbarSep1", 1);
  			mainLocalSystemToolbar.addText("homeTitleToolbar2", 2, "<?php echo $unameExec; ?>");
  			
  			// Tabbar init
				tabbar = new dhtmlXTabBar("a_tabbar");
				
				tabbar.addTab("a0", "Système", 100, 0, false, false);
				tabbar.cells("a0").attachURL("system_a0.php");
				
				tabbar.addTab("a1", "Hardware", 100, 1, false, false);
				tabbar.cells("a1").attachURL("system_a1.php");
				
				tabbar.addTab("a2", "Services", 100, 3, false, false);
				tabbar.cells("a2").attachURL("system_a2.php");
				
				tabbar.addTab("a4", "Process", 100, 4, false, false);
				tabbar.cells("a4").attachURL("system_a4.php");
				
				tabbar.addTab("a5", "Process Tree", 150, 5, false, false);
				tabbar.cells("a5").attachURL("system_a5.php");
				
				// Active tab on load
				tabbar.tabs("a0").setActive();
			}
			
		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="mainTable" style="width: 100%;" />
		<div id="myMainLocalSystemToolbar" style="width: 100%;"></div>
		<div id="a_tabbar" style="width: 100%; height: 800px; margin-left: auto; margin-right: auto;" /></div>
	</div>
	<br><br>
</body>
</html>
