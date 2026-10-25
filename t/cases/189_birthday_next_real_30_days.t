# t/cases/189_birthday_next_real_30_days.t
# =============================================================================
# Regression checks for birthday next.
#
# birthday next should use a real rolling 30-day window, including year wrap,
# instead of a simple MM-DD string comparison.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_189 {
    my ($path) = @_;

    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_189 {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    # MB954: real entry points stay compatible regardless of import order.
    require IPC::Open3;
    require Symbol;
    for my $order (
        [qw(Users::Birthdays Users::Seen UserCommands)],
        [qw(Users::Seen Users::Birthdays UserCommands)],
        [qw(UserCommands Users::Birthdays Users::Seen)],
    ) {
        my $code = "require Mediabot::$order->[0];\n";
        $code .= q{die 'domain eagerly imported facade' if $INC{'Mediabot/UserCommands.pm'};}
            if $order->[0] ne 'UserCommands';
        $code .= join('',map {"require Mediabot::$_;\n"} @$order[1..$#$order]);
        $code .= q{
            require Scalar::Util;
            require Mediabot::Mediabot;
            require Mediabot::Context;
            my %owners=(
                Birthdays=>[qw(userBirthday_ctx _birthday_add_ctx _birthday_del_ctx
                    _birthday_valid_date _birthday_mmdd_from_value _birthday_days_ahead _birthday_next_ctx)],
                Seen=>[qw(mbSeen_ctx)],
            );
            for my $owner(keys %owners){for my $name(@{$owners{$owner}}){
                my $native="Mediabot::Users::$owner"->can($name);
                my $legacy=Mediabot::UserCommands->can($name);
                die "missing alias: $name" unless $native && $legacy
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($legacy);
                next if $name =~ /^_/;
                my $method=Mediabot->can($name);
                die "missing bot method: $name" unless $method
                    && Scalar::Util::refaddr($native)==Scalar::Util::refaddr($method);
            }}
            die 'Gregorian calendar' unless !Mediabot::UserCommands::_birthday_valid_date(1900,2,29)
                && Mediabot::UserCommands::_birthday_valid_date(2000,2,29);
            local $ENV{TZ}='Europe/Paris';
            POSIX::tzset();
            my $spring=Time::Local::timelocal(0,0,12,28,2,2026);
            my $fall=Time::Local::timelocal(0,0,12,24,9,2026);
            die 'DST calendar' unless Mediabot::UserCommands::_birthday_days_ahead(3,29,$spring)==1
                && Mediabot::UserCommands::_birthday_days_ahead(10,25,$fall)==1;
            my (@notices,@public,@logs);
            {
                no warnings 'redefine';
                local *Mediabot::UserCommands::botNotice=sub {shift;push @notices,[@_]};
                local *Mediabot::UserCommands::botPrivmsg=sub {shift;push @public,[@_]};
                local *Mediabot::UserCommands::logBot=sub {shift;push @logs,[@_]};
                my $bot=bless {irc=>bless({},'MB954Load::IRC')},'MB954Load::Bot';
                my $call=sub {
                    my ($command,$args,$user)=@_;
                    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'alice',channel=>'#test',args=>$args,message=>'fixture');
                    if($user){$ctx->{_user_fetched}=1;$ctx->{user}=$user;}
                    Mediabot::UserCommands->can($command)->($ctx);
                };
                $call->('userBirthday_ctx',[]);
                die 'birthday notice hook' unless $notices[-1][1] eq 'Syntax: birthday <username>';
                $call->('mbSeen_ctx',[]);
                die 'seen notice hook' unless $notices[-1][1] =~ /^Syntax: seen /;
                $call->('userBirthday_ctx',[qw(add user bob 29/02)],bless({auth=>0},'MB954Load::User'));
                die 'birthday authentication guard' unless $notices[-1][1] =~ /^You must be logged in/;
                $call->('userBirthday_ctx',[qw(del user bob)],bless({auth=>1},'MB954Load::User'));
                die 'birthday level guard' unless $notices[-1][1] eq 'Your level does not allow you to use this command.';
                $call->('mbSeen_ctx',['bob','#test']);
                die 'seen online scope and transport' unless @public==1 && $public[0][0] eq '#test'
                    && $public[0][1] eq 'Bob is currently online on #test.' && @logs==1;
            }
            print 'checked';
            package MB954Load::User;
            sub is_authenticated {$_[0]{auth}}
            sub has_level {0}
            package MB954Load::IRC;
            sub nick_folded {'testbot'}
            package MB954Load::Bot;
            sub gethChannelNicks {{'#test'=>{},'#other'=>{}}}
            sub gethChannelsNicksOnChan {$_[1] eq '#test' ? ('Bob') : ()}
        };
        my $err=Symbol::gensym();
        my $pid=IPC::Open3::open3(undef,my $out,$err,$^X,'-I.','-It/lib','-e',$code);
        my $stdout=do {local $/;<$out>} // '';
        my $stderr=do {local $/;<$err>} // '';
        waitpid($pid,0);
        $assert->ok($?==0 && $stdout eq 'checked' && $stderr eq '',
            'mb954: calendar, guards, transports and load order: '.join('/',@$order)
                .($stderr ne '' ? " ($stderr)" : ''));
    }

    my $src = _slurp_189(
        File::Spec->catfile('.', 'Mediabot', 'Users', 'Birthdays.pm')
    );

    my $next_body = _extract_sub_body_189($src, '_birthday_next_ctx');
    my $add_body  = _extract_sub_body_189($src, '_birthday_add_ctx');

    $assert->ok(defined $next_body, '_birthday_next_ctx body found');
    $assert->ok(defined $add_body,  '_birthday_add_ctx body found');

    $assert->like(
        $src,
        qr/use Time::Local qw\(timegm timelocal\);/,
        'Birthdays imports Time::Local for date calculations (mb399: timelocal aussi)'
    );

    for my $helper (qw(_birthday_valid_date _birthday_mmdd_from_value _birthday_days_ahead)) {
        $assert->like(
            $src,
            qr/sub \Q$helper\E/,
            "$helper helper exists"
        );
    }

    $assert->like(
        $add_body // '',
        qr/_birthday_valid_date\(\$check_year, \$m, \$d\)/,
        'birthday add validates real calendar dates'
    );

    $assert->like(
        $next_body // '',
        qr/my \$window_days = 30;/,
        'birthday next defines a 30-day window'
    );

    $assert->like(
        $next_body // '',
        qr/my \$days_ahead = _birthday_days_ahead\(\$month, \$day, \$now\);/,
        'birthday next computes days ahead'
    );

    $assert->like(
        $next_body // '',
        qr/next if \$days_ahead > \$window_days;/,
        'birthday next filters birthdays outside the 30-day window'
    );

    $assert->like(
        $next_body // '',
        qr/\$a->\{days_ahead\} <=> \$b->\{days_ahead\}/,
        'birthday next sorts by days ahead'
    );

    $assert->like(
        $next_body // '',
        qr/Upcoming birthdays in the next \$window_days days:/,
        'birthday next reports the real window'
    );

    $assert->like(
        $next_body // '',
        qr/\$u->\{days_ahead\} == 0\s+\? 'today'\s+:\s+"in \$u->\{days_ahead\}d"/s,
        'birthday next displays today/in-N-days labels'
    );

    $assert->unlike(
        $next_body // '',
        qr/string comparison works for MM-DD/,
        'birthday next no longer relies on old string-comparison comment'
    );

    $assert->unlike(
        $next_body // '',
        qr/\$mmdd ge \$today/,
        'birthday next no longer uses MM-DD string comparison as its window'
    );
};
