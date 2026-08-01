# t/cases/775_mb592_examples_v2_sidecar.t
# =============================================================================
# mb592 — exemples plugins v2 du depot + chapitre cookbook.
#   [1] les 3 sidecars d'examples-v2 se chargent via load_script_v2 avec un
#       VRAI ScriptRunner pointe sur plugins/scripts (validation reelle) ;
#       commandes montees, fortune expose une commande Master.
#   [2] EXECUTION REELLE : run_script lance perl/python3/tclsh sur chaque
#       exemple — ok=1, protocol v1, une action reply non vide.
#   [3] les sidecars sont du JSON strict et coherents (api 2, name=basename).
#   [4] le cookbook documente le chapitre v2 (regles cles).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use JSON::PP ();

{
    package Bot775;
    sub new {
        require Mediabot::CommandRegistry;
        require Mediabot::ScriptRunner;
        my ($class, $dir) = @_;
        my $self = bless { registry => Mediabot::CommandRegistry->new,
                           logger => Log775->new }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(bot => $self, script_dir => $dir);
        return $self;
    }
    sub registry { $_[0]{registry} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0] }
    sub apply_actions { 1 }
    sub events { undef }
}
{
    package Log775; sub new { bless {}, shift } sub log { 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;

    my $scripts_dir = "$Bin/../../plugins/scripts";
    $assert->ok(-d "$scripts_dir/examples-v2", 'mb592-775: examples-v2 existe');

    my %expect = (
        'examples-v2/fortune.pl' => { name => 'fortune',
            cmds => { fortune => 0, fortunes => 'Master' } },
        'examples-v2/coin.py'    => { name => 'coin',
            cmds => { coin => 0 } },
        'examples-v2/lart.tcl'   => { name => 'lart',
            cmds => { lart => 0 } },
    );

    # [3] JSON strict + coherence
    for my $rel (sort keys %expect) {
        my $sidecar = "$scripts_dir/$rel.manifest.json";
        $assert->ok(-f $sidecar, "mb592-775: sidecar present — $rel");
        open my $fh, '<:raw', $sidecar or die $!;
        my $json = do { local $/; <$fh> };
        close $fh;
        my $m = eval { JSON::PP->new->decode($json) };
        $assert->ok(ref($m) eq 'HASH', "mb592-775: JSON strict — $rel");
        next unless ref($m) eq 'HASH';
        $assert->is($m->{api}, 2, "mb592-775: api 2 — $rel");
        $assert->is($m->{name}, $expect{$rel}{name},
            "mb592-775: name = basename — $rel");
    }

    # [1] chargement reel + montage
    my $bot = Bot775->new($scripts_dir);
    my $pm  = Mediabot::PluginManager->new(bot => $bot);
    for my $rel (sort keys %expect) {
        my $entry = eval { $pm->load_script_v2($rel) };
        $assert->ok($entry, "mb592-775: load_script_v2 ok — $rel")
            or next;
        for my $cmd (sort keys %{ $expect{$rel}{cmds} }) {
            $assert->is($bot->registry->has_command($cmd, 'public'), 1,
                "mb592-775: commande montee — $cmd");
            my $lvl = $bot->registry->command_for($cmd, 'public')->{level};
            $assert->is($lvl, $expect{$rel}{cmds}{$cmd},
                "mb592-775: level du sidecar porte — $cmd");
        }
    }

    # [2] execution reelle des 3 langages via le runner du depot
    for my $case (
        [ 'examples-v2/fortune.pl', 'fortune', ['irc'] ],
        [ 'examples-v2/coin.py',    'coin',    ['3']   ],
        [ 'examples-v2/lart.tcl',   'lart',    ['Canard'] ],
    ) {
        my ($rel, $cmd, $args) = @$case;
        my $result = $bot->script_runner->run_script(
            $rel, 'public_command',
            channel => '#t775', target => '#t775', nick => 'SlaY',
            command => $cmd, args => $args,
        );
        $assert->ok(ref($result) eq 'HASH' && $result->{ok},
            "mb592-775: execution reelle ok — $rel")
            or next;
        my $resp = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
        my ($reply) = grep { ($_->{type} // '') eq 'reply' }
            @{ $resp->{actions} || [] };
        $assert->ok($reply && length($reply->{text} // ''),
            "mb592-775: action reply non vide — $rel");
    }

    # [4] cookbook
    my $cb = do { open my $fh, '<:encoding(UTF-8)', "$scripts_dir/COOKBOOK.md" or die $!; local $/; <$fh> };
    $assert->like($cb, qr/## 10\. Plugin v2: declare your commands in a sidecar manifest/,
        'mb592-775: chapitre 10 v2 present');
    $assert->like($cb, qr/The sidecar is mandatory and validated/,
        'mb592-775: regle sidecar documentee');
    $assert->like($cb, qr/`level` is 0 or a USER_LEVEL description/,
        'mb592-775: regle des niveaux documentee');
    $assert->like($cb, qr/Topic, kick, ban and unban stay refused/,
        'mb597-775: gates intrusives documentees fermees');
    $assert->like($cb, qr/examples-v2\/fortune\.pl.*examples-v2\/coin\.py|fortune\.pl.*coin\.py/s,
        'mb592-775: les exemples sont references');
};
