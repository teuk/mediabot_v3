# t/cases/41_topsay_like_escape.t
# =============================================================================
# Static regression checks for topsay SQL LIKE escaping.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_topsay_like_escape {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_topsay_like_escape {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }
            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }
            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    # MB956: native calls in fresh interpreters check the import boundary,
    # the legacy API, access refusal and call-time output/progress hooks.
    require IPC::Open3;
    require Symbol;
    for my $order (
        [qw(Stats::History Stats::Affinity UserCommands)],
        [qw(Stats::Affinity Stats::History UserCommands)],
        [qw(UserCommands Stats::Affinity Stats::History)],
    ) {
        my $code = "require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly loaded facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('', map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code .= q{
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            require Mediabot::User;
            my %owners=(userTopSay_ctx=>'History',mbCompat_ctx=>'Affinity');
            for my $name(keys %owners) {
                my $native="Mediabot::Stats::$owners{$name}"->can($name);
                my $legacy=Mediabot::UserCommands->can($name);
                my $method=Mediabot->can($name);
                die "alias or method missing: $name" unless $native && $legacy && $method
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($legacy)
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($method);
            }
            my (@notice,@public,@console,@progress,@achievement,@bind);
            my $queries=0;
            no warnings 'redefine';
            local *Mediabot::UserCommands::botNotice=sub {shift;push @notice,[@_]};
            local *Mediabot::UserCommands::botPrivmsg=sub {shift;push @public,[@_]};
            local *Mediabot::UserCommands::noticeConsoleChan=sub {shift;push @console,[@_]};
            local *Mediabot::UserCommands::logBot=sub {};
            local *Mediabot::UserCommands::_ach_progress=sub {shift;push @progress,[@_];23};
            local *MB956Cold::DB::prepare=sub {
                my($s,$sql)=@_;++$queries;
                die 'wrong sayings SQL' unless $sql=~/GROUP BY publictext/ && $sql=~/LIMIT 30/;
                return bless {rows=>[map {{event_type=>'public',publictext=>"line $_",hit=>9-$_}} 1..7]},'MB956Cold::STH';
            };
            local *MB956Cold::STH::execute=sub {shift;push @bind,[@_];1};
            local *MB956Cold::STH::fetchrow_hashref=sub {shift @{$_[0]{rows}}};
            local *MB956Cold::STH::finish=sub {1};
            local *MB956Cold::IRC::nick_folded=sub {'mediabot'};
            local *MB956Cold::Message::prefix=sub {'alice!u@fixture.invalid'};
            local *MB956Cold::Logger::log=sub {};
            my $bot=bless {dbh=>bless({},'MB956Cold::DB'),irc=>bless({},'MB956Cold::IRC'),
                logger=>bless({},'MB956Cold::Logger')},'MB956Cold::Bot';
            my $call=sub {
                my($name,$channel,$args,$user)=@_;
                my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'alice',channel=>$channel,args=>$args,
                    message=>bless({},'MB956Cold::Message'));
                $ctx->{_user_fetched}=1;$ctx->{user}=$user;
                Mediabot::UserCommands->can($name)->($ctx);
            };
            my $user=Mediabot::User->new({id_user=>7,nickname=>'alice',auth=>0});
            $user->{level}=2;$user->{level_desc}='Administrator';
            $call->('userTopSay_ctx','#test',['bob'],$user);
            die 'unauthenticated sayings reached SQL' if $queries || @public;
            die 'missing authentication notice' unless $notice[-1][1]=~/must be logged in/;
            $user->{auth}=1;$user->{level}=3;$user->{level_desc}='User';
            $call->('userTopSay_ctx','#test',['bob'],$user);
            die 'User sayings reached SQL' if $queries || @public;
            die 'missing level notice' unless $notice[-1][1]=~/not available for your level/;
            $user->{level}=2;$user->{level_desc}='Administrator';
            @notice=();
            $call->('userTopSay_ctx','#test',['b%b_!'],$user);
            die 'literal nick bind changed' unless $bind[-1][0] eq '#test' && $bind[-1][1] eq 'b!%b!_!!';
            die 'sayings flooded channel' unless @public==1 && @notice==3
                && $notice[0][1]=~/topsay\[01\]/ && $notice[2][1]=~/topsay\[03\]/;
            @notice=();@public=();
            $call->('userTopSay_ctx',undef,['#test','bob'],$user);
            die 'private sayings route changed' unless !@public && @notice==4;
            my $before=$queries;
            $call->('mbCompat_ctx',undef,['bob'],undef);
            die 'private affinity reached SQL' unless $queries==$before && $notice[-1][1]=~/must be in a channel/;
            local *Mediabot::Helpers::chanset_enabled=sub {0};
            $call->('mbCompat_ctx','#test',['bob'],undef);
            die 'disabled games reached SQL' unless $queries==$before && $notice[-1][1]=~/Games are disabled/;
            local *Mediabot::Helpers::chanset_enabled=sub {1};
            my $gathers=0;
            local *Mediabot::Helpers::channel_log_gather=sub {
                my($b,$db,$sql,$bind,$row,$scope)=@_;++$gathers;
                die 'wrong affinity channel/scope' unless $bind->[0] eq '#test' && $scope eq 'content';
                if($sql=~/HOUR/) {$row->({nick=>'bob',h=>9,c=>1});$row->({nick=>'alice',h=>9,c=>1});}
                return {live_ok=>1};
            };
            local *MB956Cold::DB::prepare=sub {bless {rows=>[]},'MB956Cold::STH'};
            local *MB956Cold::Achievements::check_compat=sub {shift;push @achievement,[@_]};
            $bot->{achievements}=bless({},'MB956Cold::Achievements');
            @public=();
            $call->('mbCompat_ctx','#test',['bob'],undef);
            die 'affinity hooks changed' unless $gathers==3 && @public==3
                && $progress[0][0] eq 'compat' && $progress[0][2] eq '#test'
                && $achievement[0][0] eq 'alice' && $achievement[0][2]==23
                && $bot->{_compat_count}{alice}==1;
            print 'checked';
        };
        my $err=Symbol::gensym();
        my $pid=IPC::Open3::open3(undef,my $out,$err,$^X,'-I.','-It/lib','-e',$code);
        my $stdout=do{local $/;<$out>} // '';
        my $stderr=do{local $/;<$err>} // '';
        waitpid($pid,0);
        $assert->ok($?==0 && $stdout eq 'checked' && $stderr eq '',
            'mb956: API, role gates, literal nick, pagination and affinity hooks: '.join('/',@$order)
                .($stderr ne '' ? " ($stderr)" : ''));
    }

    my $src  = _slurp_topsay_like_escape(File::Spec->catfile('.', 'Mediabot', 'Stats', 'History.pm'));
    my $func = _extract_sub_topsay_like_escape($src, 'userTopSay_ctx');

    $assert->ok(
        $func =~ /CHANNEL_LOG\.nick LIKE \? ESCAPE '!'/,
        q{topsay nick filter uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/!\/!!\/g/,
        'topsay escapes LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/%\/!%\/g/,
        'topsay escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/_\/!_\/g/,
        'topsay escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /execute\(\$chan, \$target_nick_like\)/,
        'topsay executes query with escaped nick pattern'
    );

    $assert->ok(
        $func !~ /execute\(\$chan, \$target_nick\)/,
        'topsay no longer executes query with raw nick pattern'
    );

    $assert->ok(
        $func !~ /CHANNEL_LOG\.nick LIKE \?\n/,
        'topsay no longer uses unescaped nick LIKE'
    );
};
