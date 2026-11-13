use strict;
use warnings;
use Scalar::Util qw(refaddr);

# Execute the exact owner methods without importing the unrelated bot startup
# dependency graph. DBI statement outcomes and timer installation are controlled.
return sub {
    my ($a) = @_;
    open my $fh, '<', 'Mediabot/Mediabot.pm' or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my $code = 'package MB1280::Bot; use strict; use warnings;';
    for my $name (qw(rebuild_channel_cache populateChannels rehash_runtime_state)) {
        my ($body) = $src =~ /^(sub \Q$name\E \{.*?)(?=^sub \w+|\z)/ms;
        die "missing $name" unless $body;
        $code .= $body;
    }
    { no warnings 'redefine'; eval $code; die $@ if $@; }
    my $factory = sub { bless $_[1], 'MB1280::Channel' };
    no warnings 'redefine';
    local *Mediabot::Channel::new = $factory;
    my $diagnostic = 'fixture database failure';
    local *DBI::errstr = \$diagnostic;
    for my $mode (qw(prepare execute fetch_throw fetch_error finish_throw finish_false success empty)) {
        my $old = {'#old' => bless({name => '#old'}, 'MB1280::Channel')};
        my $timers = {old => 1};
        my $sth = bless {mode => $mode, rows => 0}, 'MB1280::Statement';
        my $bot = bless {channels => $old, timers => $timers,
            dbh => bless({sth => $sth}, 'MB1280::DB'),
            logger => bless({}, 'MB1280::Logger')}, 'MB1280::Bot';
        $sth->{observe} = sub { die "premature publication" if refaddr($bot->{channels}) != refaddr($old) };
        my $ok = eval { $bot->rebuild_channel_cache };
        my $error = $@;
        my $success = $mode eq 'success' || $mode eq 'empty';
        $a->is($ok ? 1 : 0, $success ? 1 : 0, "$mode: rebuild result");
        if (!$success) {
            $a->is(refaddr($bot->{channels}), refaddr($old), "$mode: live cache retained");
            $a->is(refaddr($bot->{timers}), refaddr($timers), "$mode: timer owner retained");
            $a->is($bot->{arms} // 0, 0, "$mode: no timer rebuild");
            $a->is(join(',', sort keys %{$old}), '#old', "$mode: no partial channel leaks");
            $a->is($error =~ /fixture/ ? 1 : 0, $mode =~ /throw/ ? 1 : 0, "$mode: exception preserved");
        } else {
            $a->is($error, '', "$mode: no exception");
            $a->is(refaddr($bot->{channels}) != refaddr($old) ? 1 : 0, 1, "$mode: replacement published");
            $a->is($bot->{arms}, 1, "$mode: timers rebuilt once");
            $a->is(join(',',sort keys %{$bot->{channels}}), $mode eq 'empty' ? '' : '#new', "$mode: complete canonical snapshot");
            $a->is(join(',',sort keys %{$old}), '#old', "$mode: detached old map unmodified");
        }
        delete $sth->{observe};
    }
    # MB1281: propagate explicit timer refusal through the real rehash method.
    require Mediabot::Channel::NicklistTimers;
    for my $mode (qw(no_loop false throw success)) {
        my @phases;
        my $timers = {old => 1};
        my $bot = bless {channels => {'#old'=>{}}, timers=>$timers,
            conf=>bless({},'MB1281::Conf'),
            logger=>bless({events=>[]},'MB1280::Logger')}, 'MB1280::Bot';
        local *MB1280::Bot::readConfigFile = sub {push @phases,'config';1};
        local *MB1280::Bot::reload_logger_from_config = sub {push @phases,'logger';1};
        local *MB1280::Bot::populateChannels = sub {$_[1]{'#new'}={};push @phases,'channels';1};
        local *MB1280::Bot::setup_channel_nicklist_timers = sub {
            push @phases,'timers';
            return Mediabot::Channel::NicklistTimers::setup($_[0]) if $mode eq 'no_loop';
            return 0 if $mode eq 'false';
            die "fixture timer failure\n" if $mode eq 'throw';
            $_[0]{timers}={new=>1};return 1;
        };
        my $ok=eval {$bot->rehash_runtime_state};my $error=$@;
        my $success=$mode eq 'success';
        my $messages=join("\n",@{$bot->{logger}{events}});
        $a->is($ok?1:0,$success?1:0,"$mode: rehash result follows timer outcome");
        $a->is($error,$mode eq 'throw'?"fixture timer failure\n":'',"$mode: timer exception unchanged");
        $a->is(join(',',@phases),'config,logger,channels,timers',"$mode: stage order preserved");
        $a->is(join(',',keys %{$bot->{channels}}),'#new',"$mode: confirmed channels remain published");
        $a->is(refaddr($bot->{timers})==refaddr($timers)?1:0,$success?0:1,"$mode: no fictitious rollback or extra timer mutation");
        $a->is($messages =~ /Channel cache rebuilt/ ?1:0,$success?1:0,"$mode: cache success only on completed setup");
        $a->is($messages =~ /Rehash runtime state completed/ ?1:0,$success?1:0,"$mode: whole rehash success only on completed setup");
        $a->is($messages =~ /channel snapshot published; nicklist timer setup incomplete/ ?1:0,($mode eq 'false'||$mode eq 'no_loop')?1:0,"$mode: explicit partial-stage diagnostic");
    }

};

package MB1280::Logger;
sub log { push @{$_[0]{events}}, $_[2]; 1 }
package MB1280::DB;
sub prepare { return if $_[0]{sth}{mode} eq 'prepare'; $_[0]{sth} }
package MB1280::Statement;
sub execute { $_[0]{mode} ne 'execute' }
sub fetchrow_hashref {
    my ($s)=@_; $s->{observe}->();
    return if $s->{mode} eq 'empty';
    return {id_channel=>2,name=>'#New'} unless $s->{rows}++;
    die "fixture fetch exception\n" if $s->{mode} eq 'fetch_throw';
    return;
}
sub err { $_[0]{mode} eq 'fetch_error' ? 1 : undef }
sub finish { die "fixture finish exception\n" if $_[0]{mode} eq 'finish_throw'; $_[0]{mode} ne 'finish_false' }
package MB1280::Bot;
sub setup_channel_nicklist_timers { $_[0]{arms}++; $_[0]{timers} = {}; 1 }

package MB1281::Conf;
sub get {0}
