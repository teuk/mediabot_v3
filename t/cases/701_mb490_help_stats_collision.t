# t/cases/701_mb490_help_stats_collision.t
# =============================================================================
# mb490 — help stats collision guard
#
# mb488 promised that when a token is both a category name and an actual command,
# the command wins (help stats -> help for the stats command). The production
# code still had a legacy shortcut that routed "help stats" to the stats category
# before the command branch. This source-level guard keeps the promise real.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_701 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _body_701 {
    my ($src, $name) = @_;
    return '' unless $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $1;
}

return sub {
    my ($assert) = @_;

    my $med = _slurp_701(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $help = _body_701($med, 'mbHelp_ctx');

    $assert->ok($help ne '', 'mbHelp_ctx localisé');
    $assert->like($med, qr/^stats\|stats \[nick\]\|public\|/m,
        'stats est documenté comme commande publique');
    # mb583: stats part en worker async — l'entree du dispatch enveloppe
    # mbStats_ctx dans CommandAsync::run_ctx_async, la cible reste la meme.
    $assert->like($med,
        qr/^\s*stats\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(.*mbStats_ctx\(\$ctx\)/m,
        'stats est dans le dispatch public (via CommandAsync mb583)');

    $assert->unlike($help, qr/\(\?:stats\|logs\|tools\)/,
        'pas de raccourci legacy qui capture help stats avant la commande');
    $assert->like($help, qr/\(\?:logs\|tools\)/,
        'logs/tools restent aliases de la catégorie stats');

    my $pos_cat = index($help, 'exists $cats{$canon}');
    my $pos_cmd = index($help, 'if ($first ne \'\' && !isIrcChannelTarget($first)) {');
    $assert->ok($pos_cat >= 0 && $pos_cmd >= 0 && $pos_cat < $pos_cmd,
        'branche catégorie avant branche commande, avec garde !exists internal');
    $assert->like($help, qr/exists \$cats\{\$canon\} && !exists \$internal\{\$key\}/,
        'la garde commande-prioritaire existe');
};
