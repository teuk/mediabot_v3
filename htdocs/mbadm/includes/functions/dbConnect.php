<?php
	//Include database connection details
	require_once('includes/conf/config.php');
	
	//Connect to mysql server
	$link = mysqli_connect(DB_HOST, DB_USER, DB_PASSWORD, DB_DATABASE);
	if(!$link) {
		die('Failed to connect to server: ' . mysqli_connect_errno());
	}
	
	mysqli_query($link,"SET NAMES 'utf8'");
	mysqli_query($link,"SET CHARACTER SET utf8");
	mysqli_query($link,"SET COLLATION_CONNECTION = 'utf8_general_ci'");
?>