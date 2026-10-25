# t/cases/640_mb425_roll_adv_dropped_die_irc.t
# =============================================================================
# mb425 — !roll adv/dis : le dé écarté utilise le barré IRC, pas Markdown.
#
# L'affichage advantage/disadvantage montrait le dé abandonné en "~~8~~"
# (strikethrough Markdown/Discord), qui apparaît en tildes littéraux sur IRC.
# mb425 utilise le vrai code de barré IRC \x1e (rendu par mIRC/HexChat/WeeChat/
# Kiwi) suivi d'un reset \x0f, en gardant le nombre lisible partout.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_640 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # MB953: verify actual commands, public aliases and late transports in
    # fresh interpreters; all three load orders use the same native checks.
    require IPC::Open3;
    require Symbol;
    for my $order (
        [qw(Games::Chance Games::Duel UserCommands)],
        [qw(Games::Duel Games::Chance UserCommands)],
        [qw(UserCommands Games::Chance Games::Duel)],
    ) {
        my $code = "require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly loaded facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('', map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code .= q{
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            my %owners = (
                Chance => [qw(mb8ball_ctx mbSlap_ctx mbRoll_ctx mbFlip_ctx mbChoose_ctx)],
                Duel => [qw(mbDuel_ctx)],
            );
            for my $owner (keys %owners) {
                for my $name (@{$owners{$owner}}) {
                    my $native = "Mediabot::Games::$owner"->can($name);
                    my $legacy = Mediabot::UserCommands->can($name);
                    my $method = Mediabot->can($name);
                    die "missing command: $name" unless $native && $legacy && $method
                        && Scalar::Util::refaddr($native) == Scalar::Util::refaddr($legacy)
                        && Scalar::Util::refaddr($native) == Scalar::Util::refaddr($method);
                }
            }
            my (@public, @notice, @actions, @logs);
            {
                no warnings 'redefine';
                local *Mediabot::UserCommands::botPrivmsg = sub {shift; push @public, [@_]};
                local *Mediabot::UserCommands::botNotice = sub {shift; push @notice, [@_]};
                local *Mediabot::UserCommands::botAction = sub {shift; push @actions, [@_]};
                local *Mediabot::UserCommands::logBot = sub {shift; push @logs, [@_]};
                local *Mediabot::Helpers::channel_lang = sub {'fr'};
                my $bot = {};
                my $call = sub {
                    my ($name,$channel,$args)=@_;
                    Mediabot::UserCommands->can($name)->(Mediabot::Context->new(
                        bot=>$bot,nick=>'alice',channel=>$channel,args=>$args,message=>'fixture'));
                };
                srand(953);
                $call->('mb8ball_ctx','#test',[]);
                die '8ball notice hook' unless $notice[-1][1] eq 'Syntax: 8ball <question>';
                $call->('mb8ball_ctx','#test',['question?']);
                die '8ball badge' unless $public[-1][1] =~ /\[8ball\].*alice:/;
                $call->('mbSlap_ctx','#test',['bob']);
                die 'slap action hook' unless @actions==1 && $actions[0][0] eq '#test'
                    && $actions[0][1] =~ /^slaps bob with /;
                $call->('mbRoll_ctx','#test',['1d20','adv']) for 1..7;
                die 'bounded dice history' unless @{$bot->{_roll_history}{'#test'}}==5;
                die 'native dice formatting' unless $public[-1][1] =~ /\x1e\d+\x0f/;
                $call->('mbRoll_ctx','#other',['history']);
                die 'dice channel isolation' unless $public[-1][1] eq 'alice: no roll history on #other.';
                $call->('mbFlip_ctx','#test',['25']);
                $call->('mbFlip_ctx','#test',['stats']);
                die 'bounded coin count' unless $public[-1][1] =~ /10 total\z/;
                $call->('mbFlip_ctx','#other',['stats']);
                die 'coin channel isolation' unless $public[-1][1] eq 'alice: no flips yet on #other.';
                $call->('mbChoose_ctx','#test',['tea','|','coffee','|','TEA']) for 1..7;
                die 'choice history' unless @{$bot->{_choose_history}{'#test'}}==5;
                die 'choice dedup notice' unless $notice[-1][1] eq 'Note: 1 duplicate option(s) removed.';
                $call->('mbChoose_ctx','#test',['last']);
                die 'last choice' unless $public[-1][1] eq 'alice: last choice was: '.$bot->{_choose_last}{'#test'};
                $call->('mbChoose_ctx','#other',['last']);
                die 'choice channel isolation' unless $public[-1][1] eq 'alice: no previous choice on this channel.';
                $call->('mbDuel_ctx',undef,['bob']);
                die 'duel private guard' unless $notice[-1][1] eq 'Syntax: !duel <nick>  (must be in a channel)';
                {
                    local *Mediabot::Helpers::chanset_enabled = sub {0};
                    $call->('mbDuel_ctx','#test',['bob']);
                }
                die 'duel chanset guard' unless $notice[-1][1] eq 'Games are disabled on #test (chanset -Games)';
                die 'logging hook' unless @logs >= 17;
            }
            print 'checked';
        };
        my $err = Symbol::gensym();
        my $pid = IPC::Open3::open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-e', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'checked' && $stderr eq '',
            'mb953: real game paths, public aliases and load order: '.join('/',@$order)
                . ($stderr ne '' ? " ($stderr)" : ''));
    }

    my $src = _slurp_640(File::Spec->catfile('.', 'Mediabot', 'Games', 'Chance.pm'));
    my ($body) = $src =~ /(sub mbRoll_ctx \{.*?\n\}\n)/s; $body //= '';
    $assert->ok($body ne '', 'mbRoll_ctx extraite');
    (my $code = $body) =~ s/^\s*#.*$//mg;

    # Plus de strikethrough Markdown.
    $assert->unlike($code, qr/~~%d~~/, 'plus de barré Markdown ~~..~~');
    $assert->unlike($code, qr/~~/,     'aucun ~~ résiduel');

    # Le dé écarté est barré via \x1e ... \x0f.
    $assert->like($code, qr/\$drop_str = "\\x1e\$drop\\x0f";/,
        'dé écarté barré via \x1e/\x0f (codes IRC)');
    $assert->like($code, qr/\[%d, %s\]/, 'format: kept + drop_str');

    # --- Simulation du rendu ----------------------------------------------
    my ($kept,$drop,$adv_mode,$label,$nick,$modifier)=(15,8,'adv','1d20','teuk',0);
    my $total=$kept+$modifier; my $mod_str=$modifier?sprintf(' %+d = %d',$modifier,$total):'';
    my $drop_str="\x1e$drop\x0f";
    my $out=sprintf('%s rolled %s (%s): [%d, %s]%s',$nick,$label,$adv_mode,$kept,$drop_str,$mod_str);
    $assert->ok(index($out, "\x1e8\x0f") >= 0, 'le dé écarté est bien barré (8 entre \x1e et \x0f)');
    $assert->ok(index($out, '~~') < 0,          'aucun tilde dans la sortie');

    $assert->like($src, qr/mb425-R1/, 'tag mb425-R1');
};
