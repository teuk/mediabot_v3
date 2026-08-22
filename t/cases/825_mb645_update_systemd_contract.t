# t/cases/825_mb645_update_systemd_contract.t
# =============================================================================
# mb645 — contrat systemd de l'auto-update.
#
# Le bug terrain etait simple mais profond : deploy_update.sh envoie SIGTERM,
# catch_term() effectue un clean_and_exit(0), tandis que l'unite publiee avait
# Restart=on-failure. Une update reussie pouvait donc laisser le bot arrete.
#
# Le contrat verrouille ici trois proprietes :
#   * Restart=always : compatibilite avec les anciennes releases qui sortent 0;
#   * ExitType=cgroup: l'updater detache finit la bascule AVANT le restart;
#   * exit 75         : `die` / `.die` restent de vrais arrets volontaires.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub slurp_utf8 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

return sub {
    my ($assert) = @_;

    my $unit   = slurp_utf8('tools/systemd/mediabot@.service.example');
    my $readme = slurp_utf8('tools/systemd/README.md');
    my $deploy = slurp_utf8('install/deploy_update.sh');
    my $update = slurp_utf8('Mediabot/Update.pm');
    my $main   = slurp_utf8('mediabot.pl');
    my $admin  = slurp_utf8('Mediabot/AdminCommands.pm');
    my $party  = slurp_utf8('Mediabot/Partyline.pm');
    my $priv   = slurp_utf8('Mediabot/Partyline/Privileged.pm');
    my $core   = slurp_utf8('Mediabot/Mediabot.pm');

    # [1] Le template Git reste le meme modele multi-instance que teuk.org.
    $assert->like($unit, qr/^EnvironmentFile=\/etc\/default\/mediabot-%i$/m,
        'mb645-825: template multi-instance conserve');
    $assert->like($unit, qr/^WorkingDirectory=\/$/m,
        'mb645-825: WorkingDirectory historique conserve');
    $assert->like($unit,
        qr{^ExecStart=/bin/bash -lc 'cd "\$BOT_DIR" && exec /usr/bin/stdbuf -oL -eL /usr/bin/perl "\$BOT_BIN" --conf="\$BOT_CONF"'$}m,
        'mb645-825: ExecStart eprouve de teuk.org conserve');
    $assert->ok($unit !~ m{BOT_DIR=/home/mediabot/mediabot_v3},
        'mb645-825: aucune instance dev hardcodee dans le template');

    # [2] Contrat systemd de l'update.
    $assert->like($unit, qr/^ExitType=cgroup$/m,
        'mb645-825: ExitType=cgroup attend la fin de l updater');
    $assert->like($unit, qr/^Restart=always$/m,
        'mb645-825: sortie propre d une ancienne release redemarre');
    $assert->like($unit, qr/^SuccessExitStatus=75$/m,
        'mb645-825: exit 75 est un arret volontaire propre pour systemd');
    $assert->like($unit, qr/^RestartPreventExitStatus=75$/m,
        'mb645-825: exit 75 interdit le restart volontaire');
    $assert->like($unit, qr/^Environment=MEDIABOT_SYSTEMD_UPDATE_SAFE=1$/m,
        'mb645-825: template annonce explicitement le nouveau contrat au bot');
    $assert->like($unit, qr/^RestartSec=10s$/m,
        'mb645-825: temporisation historique conservee');

    $assert->like($readme, qr/systemd 250/,
        'mb645-825: prerequis ExitType=cgroup documente');
    $assert->like($readme, qr/SuccessExitStatus=/,
        'mb645-825: arret volontaire marque comme succes documente');
    $assert->like($readme, qr/RestartPreventExitStatus=/,
        'mb645-825: absence de restart volontaire documentee');
    $assert->like($readme, qr/systemctl stop mediabot\@dev/,
        'mb645-825: arret administratif documente');

    # [3] deploy_update refuse de tuer le bot si la vraie unite n'a pas la
    # policy requise. La garde doit etre strictement AVANT kill -15.
    my $guard = index($deploy, 'systemd unit ${SYSTEMD_UNIT} is not update-safe');
    my $kill  = index($deploy, 'kill -15 "$BOT_PID"');
    $assert->ok($guard >= 0 && $kill >= 0 && $guard < $kill,
        'mb645-825: policy systemd verifiee avant SIGTERM');
    $assert->like($deploy, qr{/proc/\$\{BOT_PID\}/cgroup},
        'mb645-825: unite deduite du vrai cgroup du PID');
    $assert->like($deploy, qr/--property=Restart --value/,
        'mb645-825: Restart lu depuis systemd');
    $assert->like($deploy, qr/--property=ExitType --value/,
        'mb645-825: ExitType lu depuis systemd');
    $assert->like($deploy, qr/\[ "\$SYSTEMD_RESTART" != "always" \].*\[ "\$SYSTEMD_EXIT_TYPE" != "cgroup" \]/s,
        'mb645-825: les deux proprietes sont obligatoires');
    $assert->like($update, qr/restart policy is verified before shutdown/,
        'mb645-825: IRC ne promet plus un restart sans verification');

    # [4] `die` / `.die` gardent leur semantique finale avec Restart=always.
    require Mediabot::Mediabot;
    my $b = bless { shutdown_exit_code => 0 }, 'Mediabot';
    $assert->is($b->getNoRestartExitCode({}), 0,
        'mb645-825: ancien template / manuel garde exit 0');
    $assert->is($b->getNoRestartExitCode({ MEDIABOT_SYSTEMD_UPDATE_SAFE => '1' }), 75,
        'mb645-825: nouveau contrat reserve exit 75');
    $assert->is($b->getShutdownExitCode(), 0,
        'mb645-825: code shutdown normal par defaut = 0');
    {
        local $ENV{MEDIABOT_SYSTEMD_UPDATE_SAFE} = '1';
        $b->setShutdownExitCode($b->getNoRestartExitCode());
    }
    $assert->is($b->getShutdownExitCode(), 75,
        'mb645-825: code shutdown volontaire memorise sous nouveau template');

    $assert->like($admin,
        qr/sub mbQuit_ctx.*?setShutdownExitCode\(\$self->getNoRestartExitCode\(\)\).*?\$self->\{Quit\} = 1/s,
        'mb645-825: commande die arme exit 75 avant QUIT');
    $assert->like($priv,
        qr/sub _cmd_die.*?setShutdownExitCode\(\$bot->getNoRestartExitCode\(\)\).*?\$bot->\{Quit\} = 1/s,
        'mb645-825: Partyline .die arme exit 75 avant QUIT');

    my $quit_exit_uses = () = $main =~ /clean_and_exit\(\$mediabot->getShutdownExitCode\(\)\)/g;
    $assert->is($quit_exit_uses, 3,
        'mb645-825: les trois sorties apres Quit propagent le code shutdown');

    # SIGTERM reste une sortie propre. C'est indispensable pour la compat avec
    # les anciennes releases; Restart=always prend ensuite le relais. Un
    # systemctl stop explicite reste gere par systemd et n'est pas redemarre.
    $assert->like($main,
        qr/sub catch_term.*?clean_and_exit\(0\).*?exit 0;/s,
        'mb645-825: SIGTERM reste un shutdown propre');

    # Le script de mise a jour reste detache par session mais dans le cgroup
    # systemd; ne pas introduire systemd-run/scope qui casserait ExitType=cgroup.
    $assert->like($update, qr/setsid\(\)/,
        'mb645-825: updater conserve son detachement de session');
    $assert->ok($update !~ /systemd-run/,
        'mb645-825: updater ne quitte pas le cgroup via systemd-run');
};
