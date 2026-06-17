# t/cases/506_mb282_end_to_end_apply_chain.t
# =============================================================================
# Couverture bout-en-bout (mb282) de la chaîne complète d'application :
#
#     ScriptRunner->run_script()  (sous-processus perl RÉEL)
#         -> decode_script_response()
#         -> ScriptActionRunner->apply_actions()  (apply + allow_irc)
#             -> IRC réel (mock enregistreur) + log
#
# Les tests apply existants (425_mb186) utilisent un script_result moqué, et les
# tests de pont (418_mb179) dépendent de DBI. Ce test exerce la chaîne réelle de
# bout en bout, sans DBI ni tclsh (un interpréteur perl suffit), et verrouille :
#   - la commande canonique + les données propres reçues par le script (mb284/289) ;
#   - l'application réelle IRC/log et le gate allow_irc (mb186) ;
#   - le contrat ok=false -> aucune action appliquée.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../..";
use File::Temp qw(tempdir);
use Test::More;

require Mediabot::ScriptRunner;
require Mediabot::ScriptActionRunner;

# --- Mocks enregistreurs (IRC + logger) ---
{
    package T::Irc;
    sub new { bless { sent => [] }, shift }
    sub can { my ($s, $m) = @_; return $m eq 'send_message'; }
    sub send_message { my ($s, @a) = @_; push @{ $s->{sent} }, [ @a ]; return 1; }
}
{
    package T::Log;
    sub new { bless { info => [], error => [] }, shift }
    sub can { my ($s, $m) = @_; return ($m eq 'info' || $m eq 'error'); }
    sub info  { push @{ $_[0]{info} },  $_[1]; }
    sub error { push @{ $_[0]{error} }, $_[1]; }
}

my $perl = $^X;
plan skip_all => 'perl interpreter not found' unless $perl && -x $perl;

my $dir = tempdir(CLEANUP => 1);

# Script qui renvoie un reply + un log, en écho de la commande canonique reçue.
open my $g, '>', "$dir/greet.pl" or die $!;
print {$g} <<'PL';
use strict; use warnings; use JSON::PP;
my $in = do { local $/; <STDIN> };
my $d = eval { decode_json($in) } || {};
my $cmd  = $d->{data}{command} // '?';
my $chan = $d->{data}{channel} // '#x';
my $n    = scalar @{ $d->{data}{args} // [] };
print encode_json({ ok => JSON::PP::true, actions => [
    { type => 'reply', target => $chan, text => "hi from $cmd ($n args)" },
    { type => 'log',   level  => 'info', text => "ran $cmd" },
] });
PL
close $g;

# Script qui échoue explicitement (ok=false) : aucune action ne doit s'appliquer.
open my $f, '>', "$dir/fail.pl" or die $!;
print {$f} <<'PL';
use strict; use warnings; use JSON::PP;
my $in = do { local $/; <STDIN> };
print encode_json({ ok => JSON::PP::false, errors => ['refused by script'],
    actions => [ { type => 'reply', target => '#x', text => 'should not be sent' } ] });
PL
close $f;

my $sr = Mediabot::ScriptRunner->new(script_dir => $dir, timeout => 5);

# === 1) Chaîne complète apply + allow_irc ===
{
    my $irc = T::Irc->new;
    my $log = T::Log->new;
    my $ar  = Mediabot::ScriptActionRunner->new(bot => { irc => $irc, logger => $log });

    # NB : la canonicalisation de la commande (mb284) est faite par ScriptDryRun
    # AVANT d'appeler ScriptRunner. Le contrat de ScriptRunner est de recevoir le
    # token déjà canonique. On lui passe donc 'hello' et on vérifie surtout le
    # nettoyage des données (args : refs/undef retirés -> 2 scalaires conservés).
    my $res = $sr->run_script('greet.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'hello',
        args => [ 'a', { bad => 1 }, undef, 'b' ]);

    ok($res->{ok}, 'real subprocess ran and returned ok');
    is($res->{lang}, 'perl', 'result exposes resolved language');

    my $applied = $ar->apply_actions($res, { channel => '#teuk' }, apply => 1, allow_irc => 1);
    ok($applied->{applied_ok}, 'apply chain fully applied with allow_irc');
    is(scalar(@{ $applied->{applied} }), 2, 'both actions applied (reply + log)');
    is(scalar(@{ $applied->{apply_errors} }), 0, 'no apply errors');

    is(scalar(@{ $irc->{sent} }), 1, 'exactly one IRC message sent');
    is($irc->{sent}[0][0], 'PRIVMSG', 'IRC command is PRIVMSG');
    is($irc->{sent}[0][2], '#teuk', 'IRC target is the channel');
    like($irc->{sent}[0][3], qr/\Ahi from hello \(2 args\)\z/,
        'script received the command and CLEANED args (refs/undef dropped -> 2 scalars)');
    is(scalar(@{ $log->{info} }), 1, 'one log line written');
    is($log->{info}[0], 'ran hello', 'log line echoes the command');
}

# === 2) Gate allow_irc : apply sans allow_irc -> pas d'IRC, log appliqué ===
{
    my $irc = T::Irc->new;
    my $log = T::Log->new;
    my $ar  = Mediabot::ScriptActionRunner->new(bot => { irc => $irc, logger => $log });

    my $res = $sr->run_script('greet.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'hello');

    my $applied = $ar->apply_actions($res, { channel => '#teuk' }, apply => 1, allow_irc => 0);
    is(scalar(@{ $irc->{sent} }), 0, 'no IRC sent when allow_irc is off');
    is(scalar(@{ $log->{info} }), 1, 'log action still applied without allow_irc');
    ok(!$applied->{applied_ok}, 'apply is not fully applied (reply blocked by allow_irc gate)');
    ok((grep { ($_->{error} // '') =~ /allow_irc/ } @{ $applied->{apply_errors} }),
        'apply_errors explains the reply was blocked by allow_irc');
}

# === 3) Contrat ok=false : aucune action appliquée ===
{
    my $irc = T::Irc->new;
    my $log = T::Log->new;
    my $ar  = Mediabot::ScriptActionRunner->new(bot => { irc => $irc, logger => $log });

    my $res = $sr->run_script('fail.pl', 'public_command',
        channel => '#teuk', nick => 'teuk', command => 'hello');

    ok(!$res->{ok}, 'script ok=false makes the run result not ok');
    my $applied = $ar->apply_actions($res, { channel => '#teuk' }, apply => 1, allow_irc => 1);
    is(scalar(@{ $irc->{sent} }), 0, 'no IRC sent for a failed (ok=false) script result');
    ok(!$applied->{applied_ok}, 'failed script result is not applied');
}

done_testing();
