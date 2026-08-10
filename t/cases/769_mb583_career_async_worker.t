# t/cases/769_mb583_career_async_worker.t
# =============================================================================
# mb583 — les commandes CARRIERE quittent la boucle d'evenements (terrain :
# « m lb » a fige le bot 60 s avant que MariaDB ne tue la requete).
#   [1] facade unitaire SANS fork : _collect_intents_run pose des facades
#       locales sur botPrivmsg/botNotice/botAction de UserCommands, collecte
#       les messages en intents ORDONNES, borne a MAX_INTENTS avec drapeau
#       truncated, capture les exceptions ; les facades sont retirees apres.
#   [2] gardes structurelles du worker (moule mb559/571) : InactiveDestroy
#       sur les DEUX handles herites, connect_isolated_handle, SET SESSION
#       max_statement_time, POSIX::_exit, TERM puis KILL, verrou par canal,
#       fallback synchrone documente, rejeu parent via les VRAIS helpers
#       qualifies Mediabot::Helpers:: (AntiFlood/NoColors au rejeu), logBot
#       PAS facade (il ecrit via le dbh isole de l'enfant).
#   [3] dispatch : les 16 entrees lourdes passent par run_ctx_async ;
#       last et seen restent synchrones (LIMIT indexes).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_769 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    require Mediabot::CommandAsync;

    # [1] facade unitaire
    {
        my ($intents, $truncated, $ok, $err) =
            Mediabot::CommandAsync::_collect_intents_run(sub {
                Mediabot::UserCommands::botPrivmsg(undef, '#quebec', 'line 1');
                Mediabot::UserCommands::botNotice(undef, 'SlaY', 'note 2');
                Mediabot::UserCommands::botAction(undef, '#quebec', 'dances');
            });
        $assert->is($ok, 1, 'mb583-769: facade: code execute sans erreur');
        $assert->is(scalar @$intents, 3, 'mb583-769: 3 intents collectes');
        $assert->is(join('|', map { join(',', @$_) } @$intents),
            'privmsg,#quebec,line 1|notice,SlaY,note 2|action,#quebec,dances',
            'mb583-769: intents ordonnes et types');
        $assert->ok(!$truncated, 'mb583-769: pas de troncature sous la borne');
    }
    {
        local $Mediabot::CommandAsync::MAX_INTENTS = 5;
        my ($intents, $truncated) =
            Mediabot::CommandAsync::_collect_intents_run(sub {
                Mediabot::UserCommands::botPrivmsg(undef, '#c', "l$_") for 1 .. 8;
            });
        $assert->is(scalar @$intents, 5, 'mb583-769: borne MAX_INTENTS respectee');
        $assert->is($truncated, 1, 'mb583-769: drapeau truncated au-dela');
    }
    {
        my ($intents, $truncated, $ok, $err) =
            Mediabot::CommandAsync::_collect_intents_run(sub {
                Mediabot::UserCommands::botPrivmsg(undef, '#c', 'before');
                die "boom command\n";
            });
        $assert->ok(!$ok, 'mb583-769: exception capturee (ok faux)');
        $assert->like($err, qr/boom command/, 'mb583-769: erreur remontee');
        $assert->is(scalar @$intents, 1, 'mb583-769: intents partiels conserves');
    }
    # les facades sont locales : hors run, les vrais subs sont revenus
    $assert->ok(
        Mediabot::UserCommands->can('botPrivmsg') != \&Mediabot::CommandAsync::_collect_intents_run,
        'mb583-769: facades retirees apres le run');

    # [2] gardes structurelles
    my $mod = _slurp_769(File::Spec->catfile('Mediabot', 'CommandAsync.pm'));
    for my $pat (
        [ qr/\{InactiveDestroy\} = 1 if \$self->\{dbh\}/, 'InactiveDestroy handle bot' ],
        [ qr/\{db\}\{dbh\}\{InactiveDestroy\}/,           'InactiveDestroy handle DB obj' ],
        [ qr/connect_isolated_handle/,                    'connexion isolee dans l enfant' ],
        [ qr/SET SESSION max_statement_time/,             'borne dure max_statement_time' ],
        [ qr/POSIX::_exit\(0\)/,                          'sortie enfant par POSIX::_exit' ],
        [ qr/kill 'TERM', \$pid/,                         'timeout TERM' ],
        [ qr/kill 'KILL', \$pid/,                         'escalade KILL' ],
        [ qr/_cmd_async_jobs\}\{\$lockkey\}/,             'verrou par canal' ],
        [ qr/running '\$label' synchronously/,            'fallback synchrone documente' ],
        [ qr/Mediabot::Helpers::botPrivmsg\(\$self/,      'rejeu parent via helpers qualifies' ],
        [ qr/watch_process\(\$pid/,                       'reap via watch_process' ],
    ) {
        $assert->like($mod, $pat->[0], "mb583-769: $pat->[1]");
    }
    $assert->ok($mod !~ /local \*Mediabot::UserCommands::logBot/,
        'mb583-769: logBot PAS facade (ecrit via le dbh isole)');

    # mb585: les logs du worker transitent par le pipe — POSIX::_exit saute
    # les flushs, le logger herite perdait tout (« ARCHIVE query failed »
    # invisible pendant l'incident #quebec). L'enfant collecte, le parent
    # rejoue prefixe [worker <label>].
    {
        my $wl = Mediabot::CommandAsync::_WorkerLogger->new;
        $wl->log(3, 'hello');
        $wl->log(1, 'archive failed');
        $assert->is(scalar @{ $wl->{q} }, 2, 'mb585-769: collecteur garde les logs');
        $assert->is($wl->{q}[1][1], 'archive failed', 'mb585-769: texte conserve');
        local $Mediabot::CommandAsync::MAX_WLOGS = 3;
        my $wl2 = Mediabot::CommandAsync::_WorkerLogger->new;
        $wl2->log(4, "l$_") for 1 .. 6;
        $assert->is(scalar @{ $wl2->{q} }, 3, 'mb585-769: borne MAX_WLOGS');
        $assert->is($wl2->{dropped}, 3, 'mb585-769: surplus compte, pas perdu en silence');
    }
    $assert->like($mod, qr/\$self->\{logger\} = \$wlog/,
        'mb585-769: le logger de l enfant est le collecteur');
    $assert->like($mod, qr/\[worker \$label\]/,
        'mb585-769: rejeu parent prefixe [worker label]');
    $assert->like($mod, qr/wlogs => \\\@wlogs/,
        'mb585-769: logs embarques dans le resultat pipe (les 2 chemins)');
    $assert->like($mod, qr/further log line\(s\) dropped/,
        'mb585-769: troncature annoncee dans le journal');

    # [3] dispatch
    my $med = _slurp_769(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
    for my $cmd (qw(stats top streak wordcount when profil profile dashboard
                    compat compare heatmap milestone milestones leaderboard
                    lb chronos)) {
        # mb629: le contrat est « cette commande s'execute dans un worker »,
        # pas « run_ctx_async est le premier mot du bloc ». leaderboard/lb
        # posent desormais une porte de niveau AVANT le fork (un refus ne
        # doit pas couter un processus) ; on tolere donc ce qui precede sur
        # la meme ligne ou la suivante, mais on exige toujours le worker.
        $assert->like($med,
            qr/^\s*\Q$cmd\E\s*=>\s*sub\s*\{[^}]{0,120}?Mediabot::CommandAsync::run_ctx_async\(/ms,
            "mb583-769: $cmd passe par le worker async");
    }
    for my $cmd (qw(last seen)) {
        $assert->ok($med !~ /^\s*\Q$cmd\E\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync/m,
            "mb583-769: $cmd reste synchrone (LIMIT indexe)");
    }
    $assert->like($med, qr/^use Mediabot::CommandAsync;/m,
        'mb583-769: module charge par Mediabot.pm');
};
