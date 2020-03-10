<?php
	require_once('includes/conf/config.php');
	require_once('includes/functions/dbConnect.php');
?>
<!DOCTYPE html>
<html lang="fr-FR">
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
	<title><?php echo PORTAL_NAME ?></title>
	<link rel="icon" type="image/jpg" href="favicon.jpg">
	
	<style>
		#loginFormContainer {
			position: absolute;
			top: 40px;
			right: 10px;
  		margin-left: auto;
  		margin-right: auto;
  		margin-top:10px;
  		width: 255px;
			height:160px;
			background-color: white;
		}

		body {background-color:black;}
	</style>
	
	<!-- dhtmlx js functions -->
	<script type="text/javascript" src="codebase/dhtmlx.js"></script>

	<!-- dhtmlx css -->
	<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">
	
	<!-- dhtmlxAjax js -->
	<script type="text/javascript" src="dhtmlxAjax/codebase/dhtmlxcommon.js"></script>

	<script>
		var formData = [
				{type: "fieldset",  name: "mydata", label: "", width:200, list:[
					{type: "settings", labelWidth: 100, inputWidth: 100},
					{type: "input", label: "Utilisateur", value: "", name: "loginField0" , labelAlign: "left",validate: "NotEmpty"},
					{type: "password", label: "Mot de passe", value: "", name: "credentialField0" , labelAlign: "left",validate: "NotEmpty"},
					{type: "button", name:"loginButton",width:205,value:"Connexion"},
					{type: "label", name:"errLoginMsg",label: "",labelWidth : 200}
				]}
		];
		
		var loginForm;
		
		// authXMLRequest
		function authXMLRequest (loader) {
			if (loader.xmlDoc.responseXML != null) {
				xmlAuthXMLRequestNode = loader.xmlDoc.responseXML.getElementsByTagName("authentication" ).item(0);
				authFromXMLValue = xmlAuthXMLRequestNode.firstChild.nodeValue;
	  		return authFromXMLValue;
	  	}
	  	else {
	  		alert("Response contains no XML");
	  	}
		}
				
		function doOnLoad() {
			// Toolbar init
			var mainToolbar = new dhtmlXToolbarObject("mainToolbarContainer");
			mainToolbar.setIconsPath("codebase/imgs/");
			mainToolbar.addButton("home", 0, null, "home.png", null);
			mainToolbar.addSeparator("sep1", 1);
			mainToolbar.addText("titrePage", 2, "<b>Administration <?php echo PORTAL_NAME ?></b>");
			mainToolbar.addSeparator("sep2", 3);
			mainToolbar.attachEvent("onClick",
				function(id) {
					if ( id == "home" ) {
						window.location.replace("/mediabot");
					}
				}
			);
			
			loginForm = new dhtmlXForm("loginForm",formData);
			
			loginForm.attachEvent("onButtonClick", function(id) { 
					loginForm.validate();
					//loginFormLogin.setItemValue("errLoginMsg", "Connexion ...");
					loginFormLogin = loginForm.getItemValue("loginField0");
					loginFormCredential = loginForm.getItemValue("credentialField0");
					if ( (  loginFormLogin != "" ) && ( loginFormCredential != "" ) ) {	
						var authLoader;
						authLoader = dhtmlxAjax.postSync("xml/auth.xml.php","login=" + loginFormLogin + "&credential=" + loginFormCredential);
						//alert("Posted authLoader" + authLoader);
						authLoaderCheck = authXMLRequest(authLoader);
						//alert("authLoaderCheck = " + authLoaderCheck);
						if ( authLoaderCheck == 1 ) {
							document.location = "main.php";
						}
						
					}
				}
			);
			
			loginForm.attachEvent("onEnter", function(id) {
					loginForm.validate();
					//loginFormLogin.setItemValue("errLoginMsg", "Connexion ...");
					loginFormLogin = loginForm.getItemValue("loginField0");
					loginFormCredential = loginForm.getItemValue("credentialField0");
					if ( (  loginFormLogin != "" ) && ( loginFormCredential != "" ) ) {	
						var authLoader;
						authLoader = dhtmlxAjax.postSync("xml/auth.xml.php","login=" + loginFormLogin + "&credential=" + loginFormCredential);
						//alert("Posted authLoader" + authLoader);
						authLoaderCheck = authXMLRequest(authLoader);
						//alert("authLoaderCheck = " + authLoaderCheck);
						if ( authLoaderCheck == 1 ) {
							document.location = "main.php";
						}
						
					}
				}
			);
			loginForm.setItemFocus("loginField0");
			
		}
	</script>
</head>

<body onload="doOnLoad()">
	
		<div id="mainToolbarContainer"></div>
		<div id="loginFormContainer">
			<div id="loginForm"></div>
		</div>
</body>

</html>

