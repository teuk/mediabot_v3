<?php
	require_once('includes/conf/config.php');
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = LEVEL_USER;
	require_once('includes/auth.php');
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html lang="fr-FR">
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
	<link rel="icon" type="image/jpg" href="favicon.jpg">
	<title>Aide</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">

		<script>
			function doOnLoad() {
				// Toolbar init
  			var helpToolbar = new dhtmlXToolbarObject("myhelpToolbar");
  			helpToolbar.setIconsPath("codebase/imgs/");
  			helpToolbar.addText("helpToolbarTitle1", 0, "<b>Aide <?php echo PORTAL_NAME ?></b>");
			}

		</script>
		
</head>
<body onload="doOnLoad()">
	<div id="myhelpToolbar" style="width: 100%;"></div>
	<br>
	<div id="mediabot_archID"><img src="mediabot_arch.jpg" border="0"></div>
	<br>
	<div id="mediabot_descID" style="font-family: verdana, sans-serif">
		Mediabot V2 est écrit en Perl. Il utilise le module Net::Async::IRC et une base de données MySQL.
		<br><br>
		Le bot comprend une gestion d'<a href="#users">Utilisateurs</a> et de <a href="#channels">Channels</a>.
	</div>
	<br>
	<div style="font-family: verdana, sans-serif">
		<h3 id="users">Utilisateurs</h3>
		<div style="font-family: verdana, sans-serif">
			La gestions des utilisateurs comprend deux niveaux dans mediabot. Le niveau "global" avec les niveaux suivants :
			<br><br>
			<table cellpadding="5" cellspacing="0" border="1">
				<tr bgcolor="##0099ff"><td>Niveau</td><td>Description</td><td>Valeur</td></tr>
				<tr><td>Owner</td><td>Niveau propriétaire</td><td>0</td></tr>
				<tr><td>Master</td><td>Niveau master</td><td>1</td></tr>
				<tr><td>Administrator</td><td>Niveau administrateur</td><td>2</td></tr>
				<tr><td>User</td><td>Niveau utilisateur</td><td>3</td></tr>
			</table>
			<br>
			Le niveau "channel" qui est compris entre 0 et 500 par <a href="#channels">Channels</a>
		</div>
	</div>
	<br>
	<div style="font-family: verdana, sans-serif">
		<h3 id="channels">Channels</h3>
		Le propriétaire du channel à le niveau 500. C'est le premier utilisateur à pouvoir en ajouter d'autres sur le channel donné.
		<br>
		Pour une description des commandes en fonction du niveau de l'utilisateur sur le channel, consultez la section "Utilisateurs" de l'aide.
		<br>
		Un channel est attribué par un utilisateur de niveau global Administrator ou plus (voir la commande addchan dans la section "Administrateurs" pour ceux-ci).
	</div>
	<br><br>
</head>
<body>
</body>
</html>