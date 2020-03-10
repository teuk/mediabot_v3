<?php
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = 1;
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
<head>
    <title>Système</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
			
		<style>
			#cpuGraphHeader {
				font-family: "Verdana";
			}
			
			#diskioGraphHeader {
				font-family: "Verdana";
			}
		
		</style>
				
		<script>
			function doOnLoad() {
				// gridSytemInfoContainer init
				var gridSytemInfoContainer = new dhtmlXGridObject('mygridSytemInfoContainer');
				gridSytemInfoContainer.setImagePath("codebase/imgs/");
				gridSytemInfoContainer.setHeader("Sysinfo,Value");
				gridSytemInfoContainer.setInitWidths("150,*");
				gridSytemInfoContainer.setColAlign("left,left");
				gridSytemInfoContainer.enableAutoHeight(true,300,true);
				gridSytemInfoContainer.init();
				gridSytemInfoContainer.setColTypes("ro,ro");
				gridSytemInfoContainer.load("xml/system_a0.xml.php");
			}

		</script>
</head>
<body onload="doOnLoad()">

<div id="myLocalSystemContainer" style="position:absolute; width:100%; height:100%;">
	<div id="mygridSytemInfoContainer"></div>
	<div id="cpuGraphContainer">
		<div id="cpuGraphHeader">Average CPU Load</div>
		<div id="cpuGraphImage">
<?php
$username = 'admin';
$password = 'W3bAdminz!2016';
$image = 'https://teuk.org/mrtg/cpu-day.png';
 
$context = stream_context_create(array(
    'http' => array(
        'header'  => "Authorization: Basic " . base64_encode("$username:$password")
    )
));

// Read image path, convert to base64 encoding
$imageData = base64_encode(file_get_contents($image,false, $context));

// Format the image SRC:  data:{mime};base64,{data};
$src = 'data: '.mime_content_type($image).';base64,'.$imageData;

// Echo out a sample image
echo '<img src="' . $src . '">';
?>
		</div>
	</div>
	<div id="diskioGraphContainer">
		<div id="diskioGraphHeader">Disk I/O</div>
		<div id="diskioGraphImage">
<?php
$username = 'admin';
$password = 'W3bAdminz!2016';
$image = 'https://teuk.org/mrtg/diskio-day.png';
 
$context = stream_context_create(array(
    'http' => array(
        'header'  => "Authorization: Basic " . base64_encode("$username:$password")
    )
));

// Read image path, convert to base64 encoding
$imageData = base64_encode(file_get_contents($image,false, $context));

// Format the image SRC:  data:{mime};base64,{data};
$src = 'data: '.mime_content_type($image).';base64,'.$imageData;

// Echo out a sample image
echo '<img src="' . $src . '">';
?>
		</div>
	</div>
</div>
<br>
</body>
</html>