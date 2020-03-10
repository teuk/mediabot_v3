<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
	$runLevelInfoExec = exec("runlevel",$runLevelInfoResults);
	$currentRunlevel = "";
	for($i=0;$i<sizeof($runLevelInfoResults);$i++) {
		$currentRunlevel .= $runLevelInfoResults[$i];
	}
?>
<script>
	// Toolbar init
	var servicesToolbar = new dhtmlXToolbarObject("myServicesToolbar");
	servicesToolbar.setIconsPath("dhtmlxToolbar/codebase/imgs/");
	servicesToolbar.addText("servicesTitleToolbar1", 0, "<b>Runlevel</b>&nbsp;:&nbsp;<?php echo $currentRunlevel; ?>");
	//servicesToolbar.addSeparator("servicesSep1", 1);
	//servicesToolbar.addText("servicesTitleToolbar2", 2, "");
	
	// gridServicesContainer init
	var gridServicesContainer = new dhtmlXGridObject('mygridServicesContainer');
	gridServicesContainer.setImagePath("dhtmlxGrid/codebase/imgs/");
	gridServicesContainer.setHeader("Service,0,1,2,3,4,5,6");
	gridServicesContainer.setInitWidths("100,100,100,100,100,100,100,100");
	gridServicesContainer.setColAlign("left,left,left,left,left,left,left,left");
	gridServicesContainer.setSkin("light");
	gridServicesContainer.enableAutoHeight(true,750,true);
	gridServicesContainer.init();
	gridServicesContainer.setColTypes("ro,ro,ro,ro,ro,ro,ro,ro");
	gridServicesContainer.loadXML("xml/getServices.xml.php");
	
</script>

<div id="mygridInfoContainer3">
	<div id="myServicesToolbar" style="width: 100%;"></div>
	<div id="mygridServicesContainer"></div>
</div>