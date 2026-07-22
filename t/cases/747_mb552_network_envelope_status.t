# t/cases/747_mb552_network_envelope_status.t
# =============================================================================
# mb552 — dernier volet du plan « go tout » : le monde entre dans l'enveloppe
# (data.network en lecture seule, frais à chaque run), la santé
# d'infrastructure entre dans .status, et la partyline gagne le même traceur
# SLOW que le PRIVMSG.
#
# Contrats :
#   [1] data.network : présent quand le bot a des stats LUSERS (champs
#       whitelistés + age_seconds, jamais l'epoch brut), ABSENT sinon, et
#       les valeurs garbage du cache sont écartées champ par champ ;
#   [2] fraîcheur au rappel : un timer armé voit le réseau d'MAINTENANT au
#       fire (le cache a changé entre-temps) alors que sa config reste le
#       snapshot — la différence est prouvée dans UN même scénario ;
#   [3] .status : ligne DB up/DOWN (via ensure_connected) et ligne Loop
#       (dernier stall ou « no stall detected ») ;
#   [4] traceur SLOW PARTYLINE : garde statique (chrono autour de
#       _handle_line, log niveau 3 avec la commande) ;
#   [5] docs : README/cookbook enseignent network et sa fraîcheur ; le
#       contrat 730 évolué reste vert (vérifié par la suite).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir);

use Mediabot::EventBus;
use Mediabot::Partyline;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::ScriptDryRun;

sub _slurp_747 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L747; sub new { bless {}, shift } sub log { 1 } }

{
    package IRC747;
    sub new { bless { sent => [] }, shift }
    sub send_message { my ($self, @args) = @_; push @{ $self->{sent} }, \@args; 1 }
    sub sent { $_[0]->{sent} }
}

{
    package Bot747;
    sub new { my ($class, %h) = @_; bless {%h, logger => L747->new}, $class }
    sub events               { $_[0]->{event_bus} }
    sub script_runner        { $_[0]->{script_runner} }
    sub script_action_runner { $_[0]->{script_action_runner} }
    sub getLoop              { $_[0]->{loop} }
    sub network_stats {
        my ($self) = @_;
        my $s = $self->{net_stats};
        return ref($s) eq 'HASH' ? { %$s } : {};
    }
    sub run_script_actions_dry { die "dry path must not run in apply mode" }
}

my $script_dir = tempdir('mediabot_mb552_XXXXXX', TMPDIR => 1, CLEANUP => 1);
{
    # Fixture : echo du snapshot network + de la config recus.
    my $path = File::Spec->catfile($script_dir, 'netecho.pl');
    open my $fh, '>:encoding(UTF-8)', $path or die $!;
    print {$fh} <<'FIX';
#!/usr/bin/env perl
use strict; use warnings;
use JSON::PP qw(decode_json encode_json);
my $p = eval { decode_json(do { local $/; <STDIN> } || '{}') } || {};
my $d = ref($p->{data}) eq 'HASH' ? $p->{data} : {};
my $ev = $p->{event} // 'unknown';
my $net = ref($d->{network}) eq 'HASH' ? $d->{network} : {};
my $cfg = ref($d->{config}) eq 'HASH' ? $d->{config} : {};
my $users = defined $net->{users} ? $net->{users} : 'none';
my $tag = defined $cfg->{tag} ? $cfg->{tag} : 'none';
my @actions = ( { type => 'reply', text => "net[$ev] users=$users tag=$tag" } );
push @actions, { type => 'timer', name => 'nethold', delay => 1 }
    if $ev eq 'public_command';
print encode_json({ protocol => 'mediabot-script-v1', ok => JSON::PP::true, actions => \@actions });
FIX
    close $fh;
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Contenu et absence de data.network
    # ------------------------------------------------------------------
    {
        my $bot = Bot747->new(net_stats => {
            users => 812, users_max => 1024, channels => 128,
            servers => 2, operators => 4,
            updated_at => time() - 40,
            garbage => 'x', users_bad => 'NaN',
        });
        my $runner = Mediabot::ScriptRunner->new(bot => $bot, script_dir => $script_dir, timeout => 5);

        my $payload = $runner->build_event_payload('public_command',
            channel => '#mb552', nick => 'teuk', args => []);
        my $net = $payload->{data}{network};
        $assert->ok(ref($net) eq 'HASH' && $net->{users} == 812
            && $net->{users_max} == 1024 && $net->{operators} == 4,
            'network: champs whitelistes presents');
        $assert->ok(!exists $net->{garbage} && !exists $net->{updated_at},
            'network: whitelist stricte, pas d\'epoch brut');
        $assert->ok(defined $net->{age_seconds}
            && $net->{age_seconds} >= 40 && $net->{age_seconds} <= 45,
            'network: age en secondes');

        my $empty_bot = Bot747->new(net_stats => {});
        my $runner2 = Mediabot::ScriptRunner->new(bot => $empty_bot, script_dir => $script_dir, timeout => 5);
        my $p2 = $runner2->build_event_payload('public_command',
            channel => '#x', nick => 'n', network => { users => 999 });
        $assert->ok(!exists $p2->{data}{network},
            'network: absent sans LUSERS et injection appelant refusee');

        my $partial = Bot747->new(net_stats => { users => 'garbage', channels => 7, updated_at => time() });
        my $runner3 = Mediabot::ScriptRunner->new(bot => $partial, script_dir => $script_dir, timeout => 5);
        my $p3 = $runner3->build_event_payload('public_command', channel => '#x', nick => 'n');
        $assert->ok($p3->{data}{network}{channels} == 7
            && !exists $p3->{data}{network}{users},
            'network: valeurs garbage ecartees champ par champ');
    }

    # ------------------------------------------------------------------
    # [2] Fraîcheur au fire vs snapshot de config
    # ------------------------------------------------------------------
    my $have_loop = eval { require IO::Async::Loop; 1 };
    if (!$have_loop) {
        $assert->ok(1, 'SKIP fire: IO::Async::Loop indisponible');
    }
    else {
        my $loop = IO::Async::Loop->new;
        my $bus  = Mediabot::EventBus->new;
        my $irc  = IRC747->new;
        my $conf = {
            'plugins.ScriptDryRun.ACTION_MODE'   => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'     => 'yes',
            'plugins.ScriptDryRun.COMMANDS'      => 'netecho',
            'plugins.ScriptDryRun.ROUTES'        => 'netecho=netecho.pl',
            'plugins.ScriptDryRun.CONFIG_netecho' => 'tag=alpha',
        };
        my $bot = Bot747->new(irc => $irc, conf => $conf, event_bus => $bus, loop => $loop,
            net_stats => { users => 100, updated_at => time() });
        $bot->{script_runner} = Mediabot::ScriptRunner->new(
            bot => $bot, script_dir => $script_dir, timeout => 5, max_stdout_bytes => 65536);
        $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);
        my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

        $plugin->observe_public_command({
            channel => '#mb552', target => '#mb552', nick => 'teuk',
            command => 'netecho', args => [],
        });
        $assert->ok(($irc->sent->[0][3] || '') =~ /net\[public_command\] users=100 tag=alpha/,
            'run immediat: reseau 100, config alpha');

        # Le monde change PENDANT que le timer est arme.
        $bot->{net_stats} = { users => 999, updated_at => time() };
        $bot->{conf}{'plugins.ScriptDryRun.CONFIG_netecho'} = 'tag=omega';
        $plugin->refresh_from_conf;

        $loop->delay_future(after => 1.3)->get;
        $assert->ok(($irc->sent->[1][3] || '') =~ /net\[timer\] users=999 tag=alpha/,
            'fire: reseau FRAIS (999) mais config SNAPSHOT (alpha) — la difference prouvee');

        $plugin->unregister;
    }

    # ------------------------------------------------------------------
    # [3] .status : DB et Loop
    # ------------------------------------------------------------------
    {
        {
            package Stream747;
            sub new { bless { out => '' }, shift }
            sub write { $_[0]->{out} .= $_[1]; 1 }
            sub out { $_[0]->{out} }
        }
        {
            package DB747;
            sub new { my ($class, %h) = @_; bless { %h }, $class }
            sub can { 1 }
            sub dbh { $_[0]->{up} ? {} : undef }
            sub ensure_connected { die "status must not probe the DB\n" }
        }
        my $core_ok = eval { require Mediabot::Mediabot; 1 };
        if (!$core_ok) {
            $assert->ok(1, 'SKIP status: coeur non chargeable');
        }
        else {
            my $core = bless { logger => L747->new, db => DB747->new(up => 1),
                users => {}, _start_time => time() }, 'Mediabot';
            $core->{loop_last_stall} = { at => time() - 30, seconds => 9.02 };
            my $party = bless { bot => $core, users => {} }, 'Mediabot::Partyline';
            my $s = Stream747->new;
            eval { $party->_cmd_status($s, 1) };
            $assert->like($s->out, qr/^DB:\s+up\r?$/m, 'status: DB up');
            $assert->like($s->out, qr/^Loop:\s+last stall 9\.02s at /m, 'status: dernier stall date');

            $core->{db} = DB747->new(up => 0);
            delete $core->{loop_last_stall};
            my $s2 = Stream747->new;
            eval { $party->_cmd_status($s2, 1) };
            $assert->like($s2->out, qr/^DB:\s+DOWN\r?$/m, 'status: DB DOWN');
            $assert->like($s2->out, qr/^Loop:\s+no stall detected\r?$/m, 'status: pas de stall');
        }
    }

    # ------------------------------------------------------------------
    # [4] + [5] Gardes statiques et docs
    # ------------------------------------------------------------------
    {
        my $party_src = _slurp_747(File::Spec->catfile('Mediabot', 'Partyline.pm'));
        $assert->like($party_src, qr/SLOW PARTYLINE: %s took %\.2fs/,
            'partyline: traceur SLOW present');
        $assert->like($party_src, qr/tv_interval\(\$t0_552\)/, 'partyline: chrono HiRes reel');

        my $runner_src = _slurp_747(File::Spec->catfile('Mediabot', 'ScriptRunner.pm'));
        $assert->like($runner_src, qr/mb552-B1/, 'runner: marqueur mb552');
        $assert->unlike($runner_src, qr/`[^`]+`/, 'runner: aucun backtick apparie');

        my $readme = _slurp_747(File::Spec->catfile('plugins', 'scripts', 'README.md'));
        $assert->like($readme, qr/data\.network/, 'README: network documente');
        $assert->like($readme, qr/rebuilt FRESH at every run/, 'README: fraicheur enseignee');

        my $cookbook = _slurp_747(File::Spec->catfile('plugins', 'scripts', 'COOKBOOK.md'));
        $assert->like($cookbook, qr/data\.network/, 'cookbook: network enseigne');
    }
};
