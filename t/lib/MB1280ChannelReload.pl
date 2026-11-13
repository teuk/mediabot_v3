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
    for my $name (qw(rebuild_channel_cache populateChannels)) {
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
};

package MB1280::Logger;
sub log { 1 }
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
