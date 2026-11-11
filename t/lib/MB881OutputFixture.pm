package MB881OutputFixture;
use strict;
use warnings;
use utf8;
use Mediabot::Helpers ();

# Only integration seams and IO are replaced. Sender, TextBudget, classification,
# redaction and the deferred queue remain their production implementations.
sub new_bot {
    return bless {
        policy => {}, blocked => 0, events => [],
        logger => bless({rows => []}, 'MB881::Logger'),
        irc => bless({wire => []}, 'MB881::IRC'),
        metrics => bless({counts => {}}, 'MB881::Metrics'),
        dbh => bless({queries => [], finishes => 0, words => []}, 'MB881::DBH'),
    }, 'MB881::Bot';
}
sub with_policy {
    my ($code) = @_;
    no warnings 'redefine';
    local *Mediabot::Helpers::getIdChansetList = sub {$_[1]};
    local *Mediabot::Helpers::getIdChannelSet = sub {$_[0]{policy}{$_[2]} ? 1 : undef};
    local *Mediabot::Helpers::checkAntiFlood = sub {$_[0]{blocked} ? 1 : 0};
    local *Mediabot::Helpers::logBotAction = sub {push @{$_[0]{events}}, ['history', @_[1 .. 5]]; 1};
    local *Mediabot::Helpers::noticeConsoleChan = sub {push @{$_[0]{events}}, ['console', $_[1]]; 1};
    return $code->();
}
package MB881::Bot;
sub getLoop {$_[0]{loop}}
package MB881::Logger;
sub log {push @{$_[0]{rows}}, [$_[1], $_[2]]; 1}
package MB881::IRC;
sub nick_folded {'mediabot'}
sub do_PRIVMSG {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'privmsg', %args}; 1}
sub do_NOTICE {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'notice', %args}; 1}
package MB881::Metrics;
sub inc {$_[0]{counts}{$_[1]}++; 1}
package MB881::DBH;
sub prepare {
    my ($self, $sql) = @_;
    push @{$self->{queries}}, {sql => $sql};
    return undef if ($self->{failure} // '') eq 'prepare';
    return bless {dbh => $self, words => [@{$self->{words}}]}, 'MB881::STH';
}
package MB881::STH;
sub execute {
    my ($self, @bind) = @_;
    $self->{dbh}{queries}[-1]{bind} = \@bind;
    return ($self->{dbh}{failure} // '') eq 'execute' ? 0 : 1;
}
sub fetchrow_hashref {my $word = shift @{$_[0]{words}}; defined($word) ? {badword => $word} : undef}
sub err {0}
sub finish {$_[0]{dbh}{finishes}++; 1}
package MB881::Timer;
sub new {my ($class, %args) = @_; bless \%args, $class}
sub start {$_[0]{started} = 1; 1}
sub stop {$_[0]{stopped} = 1; 1}
package MB881::Loop;
sub new {bless {pending => [], delays => []}, shift}
sub add {push @{$_[0]{pending}}, $_[1]; push @{$_[0]{delays}}, $_[1]{delay}; 1}
sub remove {$_[1]{removed} = 1; 1}
sub tick {my $t = shift @{$_[0]{pending}}; $t->{on_expire}->() if $t}
sub drain {my ($s) = @_; my $n = 0; while (@{$s->{pending}}) {die 'fixture did not finish' if ++$n > 100; $s->tick}}
1;

# MB1235: fault matrix shared by native integration and offline package checks.
package MB1235::DB;
sub prepare {
    my ($s,$sql)=@_; push @{$s->{calls}},['prepare',$sql];
    die "prepare fault\n" if $s->{mode} eq 'prepare_throw';
    return if $s->{mode} eq 'prepare_false';
    return bless {db=>$s,rows=>[@{$s->{rows}}]},'MB1235::STH';
}
package MB1235::STH;
sub execute {
    my ($s,@bind)=@_;push @{$s->{db}{calls}},['execute',@bind];
    die "execute fault\n" if $s->{db}{mode} eq 'execute_throw';
    return 0 if $s->{db}{mode} eq 'execute_false';
    return '0E0';
}
sub fetchrow_hashref {
    my ($s)=@_;push @{$s->{db}{calls}},['fetch'];
    die "fetch fault\n" if $s->{db}{mode} eq 'fetch_throw' && !@{$s->{rows}};
    return shift @{$s->{rows}};
}
sub err {
    my ($s)=@_;push @{$s->{db}{calls}},['err'];
    die "err fault\n" if $s->{db}{mode} eq 'err_throw';
    return $s->{db}{mode} eq 'partial_error' ? 1 : 0;
}
sub finish {
    my ($s)=@_;push @{$s->{db}{calls}},['finish'];
    die "finish fault\n" if $s->{db}{mode} eq 'finish_throw';
    return $s->{db}{mode} eq 'finish_false' ? 0 : 1;
}
package MB881OutputFixture;
sub check_badword_read_contracts {
    require Test::More;
    require Mediabot::IRC::Sender;
    for my $mode (qw(success empty prepare_false prepare_throw execute_false execute_throw fetch_throw partial_error bad_row bad_value err_throw finish_throw finish_false)) {
        my $bot=new_bot();
        my $rows=$mode eq 'empty' ? [] : $mode eq 'bad_row' ? [{badword=>'partial'},[]]
            : $mode eq 'bad_value' ? [{badword=>'partial'},{badword=>[]}]
            : [{badword=>'BLoCKED'},{badword=>undef},{badword=>'BLoCKED'},{badword=>'0'}];
        my $db=bless {mode=>$mode,rows=>$rows,calls=>[]},'MB1235::DB';
        $bot->{dbh}=$db;
        my $old={ts=>1,words=>['confirmed']};
        $bot->{_badword_cache}={'#mixed_%'=>$old,'#other'=>{ts=>2,words=>['other']}};
        my $good=$mode =~ /^(success|empty|finish_throw|finish_false)$/;
        my ($result,$error);
        eval {$result=Mediabot::IRC::Sender::_badwords_for_channel($bot,'#MiXeD_%');1} or $error=$@;
        Test::More::ok(!$error,"$mode: reader/policy failure remains contained");
        my $expected=$good ? ($mode eq 'empty' ? [] : ['blocked','blocked','0']) : ['confirmed'];
        Test::More::is_deeply($result,$expected,"$mode: complete normalized list or confirmed fallback, never partial");
        Test::More::is_deeply($bot->{_badword_cache}{'#other'},{ts=>2,words=>['other']},"$mode: unrelated channel intact");
        Test::More::is($bot->{_badword_cache}{'#mixed_%'}{ts}==1 ? 1:0,$good?0:1,"$mode: only successful reads advance age");
        my @ops=map {$_->[0]} @{$db->{calls}};
        Test::More::is(scalar(grep {$_ eq 'finish'} @ops),$mode =~ /^prepare_/ ? 0:1,"$mode: acquired statement finished once");
        Test::More::is($bot->{metrics}{counts}{mediabot_db_query_errors_total}//0,$good?0:1,"$mode: exact error accounting");
        Test::More::is(scalar @{$bot->{logger}{rows}},$good?0:1,"$mode: one bounded diagnostic on failure");
        Test::More::is_deeply($db->{calls}[0],['prepare','SELECT badword FROM CHANNEL JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ?'],"$mode: exact query");
        if ($mode !~ /^prepare_/) {
            Test::More::is_deeply($db->{calls}[1],['execute','#MiXeD_%'],"$mode: original name bound literally");
        }
        my $count=scalar @{$db->{calls}};
        Mediabot::IRC::Sender::_badwords_for_channel($bot,'#mIXED_%');
        Test::More::is(scalar(@{$db->{calls}})>$count?1:0,$good?0:1,"$mode: failures retry, successes share case-insensitive cache");
        if (!$good) {
            delete $bot->{_badword_cache}{'#mixed_%'};
            Test::More::is_deeply(Mediabot::IRC::Sender::_badwords_for_channel($bot,'#MiXeD_%'),[],"$mode: first failure keeps historical empty fallback");
            Test::More::ok(!exists $bot->{_badword_cache}{'#mixed_%'},"$mode: failed initial read is not cached");
        }
    }
}
1;
