# t/cases/768_mb579_archive_once_tool.t
# =============================================================================
# mb579 — tools/archive_channel_log_once.pl : archivage PONCTUEL identique a
# la tache quotidienne du bot (Mediabot::archive_channel_log), pilote par la
# conf d'une instance.
#   [1] fidelite stricte : memes bornes (p_days 1..3650, c_days 0..36500,
#       max 5000..2000000), meme SELECT par lots (ORDER BY id_channel_log
#       LIMIT 5000), plafond strict par splice, INSERT IGNORE, et un bloc
#       VERIFY d'identite IDENTIQUE LIGNE A LIGNE a celui du bot ;
#   [2] surete : dry-run par defaut (aucune ecriture hors branche execute),
#       --loop refuse sans --execute, verify avant delete, aucun backtick,
#       le mot de passe n'est jamais imprime ;
#   [3] moule conf des outils freres (DDBNAME double-D + repli DBNAME,
#       localhost -> 127.0.0.1).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_768 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# extrait les lignes "AND arch.X = live.X" du bloc VERIFY, normalisees
sub _verify_lines_768 {
    my ($src) = @_;
    my @l;
    for my $line (split /\n/, $src) {
        next unless $line =~ /arch\.(?:id_channel|ts|event_type|nick|userhost|publictext)/;
        next unless $line =~ /=\s*(?:BINARY\s+)?(?:COALESCE\()?live\./ || $line =~ /live\./;
        $line =~ s/^\s+//; $line =~ s/\s+$//;
        $line =~ s/^[.]\s*"//; $line =~ s/"$//;   # forme concatenee " . " ... "
        $line =~ s/^"//;
        push @l, $line;
    }
    return join("\n", @l);
}

return sub {
    my ($assert) = @_;

    my $tool_path = File::Spec->catfile('tools', 'archive_channel_log_once.pl');
    $assert->ok(-f $tool_path, 'mb579-768: outil present');
    my $tool = _slurp_768($tool_path);
    my $bot  = _slurp_768(File::Spec->catfile('Mediabot', 'Mediabot.pm'));

    # [1] bornes et flux identiques au bot
    for my $lit (
        '$p_days = 1    if $p_days < 1;',
        '$p_days = 3650 if $p_days > 3650;',
        '$c_days = 0     if $c_days < 0;',
        '$c_days = 36500 if $c_days > 36500;',
        '$max_run = 5000    if $max_run < 5000;',
        '$max_run = 2000000 if $max_run > 2000000;',
        'ORDER BY id_channel_log LIMIT 5000',
        'INSERT IGNORE INTO $atable SELECT * FROM CHANNEL_LOG',
        'CREATE TABLE IF NOT EXISTS $atable LIKE CHANNEL_LOG',
        'splice(@ids, $remaining) if @ids > $remaining;',
        "ts < DATE_SUB(NOW(), INTERVAL ? DAY)",
    ) {
        $assert->ok(index($tool, $lit) >= 0, "mb579-768: outil: contient '" . substr($lit,0,48) . "'");
        $assert->ok(index($bot,  $lit) >= 0, "mb579-768: bot: contient aussi '" . substr($lit,0,48) . "'");
    }

    # le bloc VERIFY (les comparaisons arch/live) est identique ligne a ligne
    # mb581: l'outil contient desormais d'autres COUNT sur $atable (align,
    # diagnose) — le VRAI verify est le bloc qui exige aussi l'identite
    # d'id_channel ET se termine par le bind du lot (undef, @ids).
    my $verify_re = qr/(SELECT COUNT\(\*\) FROM \$atable arch(?:(?!SELECT COUNT).)*?arch\.id_channel <=> live\.id_channel(?:(?!SELECT COUNT).)*?undef, \@ids\);)/s;
    my ($bot_verify)  = $bot  =~ $verify_re;
    my ($tool_verify) = $tool =~ $verify_re;
    $assert->ok(defined $bot_verify && defined $tool_verify,
        'mb579-768: blocs VERIFY isoles dans les deux fichiers');
    $assert->is(_verify_lines_768($tool_verify), _verify_lines_768($bot_verify),
        'mb579-768: VERIFY: comparaisons d identite identiques ligne a ligne au bot');
    $assert->like($tool_verify, qr/BINARY COALESCE\(arch\.publictext,''\)/,
        'mb579-768: VERIFY: publictext compare en BINARY');

    # mb582: les comparaisons nullables sont NULL-safe dans les DEUX verify —
    # un quit reseau (id_channel NULL par design, schema DEFAULT NULL) est
    # identique a lui-meme ; l'ancien = strict le rejetait a chaque run.
    for my $pair ([outil => $tool_verify], [bot => $bot_verify]) {
        my ($who, $v) = @$pair;
        $assert->like($v, qr/arch\.id_channel <=> live\.id_channel/,
            "mb582-768: $who: id_channel compare en <=> (NULL-safe)");
        $assert->like($v, qr/arch\.ts <=> live\.ts/,
            "mb582-768: $who: ts compare en <=> (NULL-safe)");
        $assert->ok($v !~ /arch\.id_channel = live\.id_channel/,
            "mb582-768: $who: plus d egalite stricte NULL-blind sur id_channel");
    }
    $assert->like($tool, qr/both_null_chan/,
        'mb582-768: diagnose compte explicitement les both-NULL');
    my @strict_div = grep { $_ !~ /^\s*#/ && /arch\.id_channel <> live\.id_channel/ }
        split /\n/, $tool;
    $assert->is(join('|', @strict_div), '',
        'mb582-768: plus aucune divergence <> NULL-blind dans l outil');

    # [2] surete
    my ($dry_section) = $tool =~ /unless \(\$opt_execute\) \{(.*?)\n\}/s;
    $assert->ok(defined $dry_section, 'mb579-768: section dry-run isolee');
    $assert->ok($dry_section !~ /INSERT|DELETE|CREATE TABLE/,
        'mb579-768: dry-run: aucune ecriture (ni INSERT ni DELETE ni CREATE)');
    $assert->like($tool, qr/--loop requires --execute/,
        'mb579-768: garde: --loop refuse sans --execute');
    # verify AVANT delete dans le flux execute
    my $iv = index($tool, "verify failed");
    my $id = index($tool, "DELETE FROM CHANNEL_LOG WHERE id_channel_log IN");
    $assert->ok($iv >= 0 && $id >= 0 && $iv < $id,
        'mb579-768: execute: le VERIFY precede le DELETE');
    my @ticks = $tool =~ /(`[^`\n]*`)/g;
    $assert->is(join('|', @ticks), '', 'mb579-768: aucun backtick apparie');
    # le mot de passe n'apparait dans aucune sortie
    my @leaks = grep { /\$dbpass/ } grep { /say_out|say_info|print/ } split /\n/, $tool;
    $assert->is(join('|', @leaks), '', 'mb579-768: DBPASS jamais imprime');

    # [2b] mb580: --diagnose est LECTURE SEULE et incompatible avec --execute
    my ($diag_section) = $tool =~ /if \(\$opt_diag\) \{(.*?)\n\}/s;
    $assert->ok(defined $diag_section, 'mb580-768: section diagnose isolee');
    # la vraie garde lecture-seule : aucun $dbh->do( dans la section — le
    # diagnose ne passe que par selectrow/selectcol/selectall (des mots
    # comme INSERT peuvent apparaitre dans les MESSAGES affiches).
    $assert->ok($diag_section !~ /\$dbh->do\(/,
        'mb580-768: diagnose sans aucune ecriture (aucun dbh->do)');
    $assert->like($tool, qr/--diagnose is read-only and cannot be combined with --execute/,
        'mb580-768: garde diagnose vs execute');
    $assert->like($diag_section, qr/SHOW CREATE TABLE/,
        'mb580-768: diagnose compare les definitions des deux tables');
    $assert->like($diag_section, qr/HEX\(LEFT\(/,
        'mb580-768: echantillon en HEX (les encodages sautent aux yeux)');
    $assert->like($diag_section, qr/TABLE CHARSETS DIFFER/,
        'mb580-768: alerte charset explicite');
    $assert->like($diag_section, qr/id reuse suspected/,
        'mb580-768: alerte reutilisation d ids inter-epoques');

    # [2c] mb581: --align-archive-channel-ids — ecrit l'ARCHIVE seulement
    my ($align_section) = $tool =~ /if \(\$opt_align\) \{(.*?)\n\}/s;
    $assert->ok(defined $align_section, 'mb581-768: section align isolee');
    $assert->like($align_section, qr/UPDATE \$atable arch/,
        'mb581-768: align met a jour la table d archive');
    $assert->ok($align_section !~ /UPDATE CHANNEL_LOG|DELETE FROM CHANNEL_LOG|INSERT INTO CHANNEL_LOG/,
        'mb581-768: align n ecrit JAMAIS la table vive');
    $assert->like($align_section, qr/SET arch\.id_channel = live\.id_channel/,
        'mb581-768: le vif est l autorite du referentiel canaux');
    for my $f (qw(ts event_type nick userhost publictext)) {
        $assert->like($align_section, qr/\Q$f\E/,
            "mb581-768: identite align exige $f identique");
    }
    $assert->like($align_section, qr/unless \(\$opt_execute\)/,
        'mb581-768: align dry-run par defaut');
    $assert->like($tool, qr/--align-archive-channel-ids cannot be combined/,
        'mb581-768: align refuse diagnose et loop');
    $assert->like($tool, qr/mapping query failed|sample query failed/,
        'mb581-768: les requetes diagnose muettes affichent errstr');
    $assert->like($tool, qr/id_channel mapping \(live -> archive\)/,
        'mb581-768: diagnose montre la distribution du mapping avec noms');

    # [3] moule conf
    $assert->like($tool, qr/MAIN_PROG_DDBNAME'\} \/\/ \$conf->\{'mysql\.MAIN_PROG_DBNAME/,
        'mb579-768: moule: DDBNAME double-D avec repli DBNAME');
    $assert->like($tool, qr/\(\$dbhost eq 'localhost'\) \? '127\.0\.0\.1'/,
        'mb579-768: moule: localhost force en TCP');
    $assert->like($tool, qr/CHANNEL_LOG_ARCHIVE_DBNAME/,
        'mb579-768: cles archive de la conf instance lues');
    $assert->like($tool, qr/\\A\[A-Za-z0-9_\]\{1,64\}\\z/,
        'mb579-768: ARCHIVE_DBNAME valide comme dans le bot');
};
