# t/cases/407_mb168_public_command_observed_event.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $fh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($helper) = $src =~ /sub emit_event_report \{(.*?)^\}/ms;
    my ($public) = $src =~ /sub mbCommandPublic \{(.*?)^sub mbHandleNickTriggered/ms;

    $assert->(defined($helper) && length($helper) > 0,
        'emit_event_report helper exists');
    $assert->(defined($public) && length($public) > 0,
        'mbCommandPublic block extracted');

    $assert->($helper =~ /\$bus->emit_report\(\$event, \@args\)/,
        'emit_event_report delegates to EventBus::emit_report');
    $assert->($helper =~ /EventBus '\$event' listener '\$who' failed/,
        'emit_event_report logs listener failures');
    $assert->($helper =~ /return \{\s*event\s*=>\s*\$event,\s*ran\s*=>\s*0,\s*errors\s*=>\s*\[\]/s,
        'emit_event_report is safe when no bus is available');

    $assert->($public =~ /Mediabot::Context->new\(.*?Mediabot::Command->new/s,
        'public command builds Context and Command object before event');
    $assert->($public =~ /mb168-B1: first low-risk EventBus integration point/,
        'public command event has mb168 marker');
    $assert->($public =~ /\$self->emit_event_report\('public_command_observed', \$ctx\);/,
        'public command emits public_command_observed with Context');

    my $idx_ctx   = index($public, 'Mediabot::Context->new');
    my $idx_cmd   = index($public, '$ctx->{command_obj} = Mediabot::Command->new');
    my $idx_event = index($public, "emit_event_report('public_command_observed'");
    my $idx_reg   = index($public, '$self->commands->handler_for');

    $assert->($idx_ctx >= 0 && $idx_cmd > $idx_ctx && $idx_event > $idx_cmd,
        'event is emitted after Context and Command object are ready');
    $assert->($idx_reg > $idx_event,
        'event is emitted before registry/legacy dispatch');
    $assert->($public =~ /if \(my \$handler = \$self->commands->handler_for\(\$cmd, 'public'\)\)/,
        'registry dispatch still exists after event');
    $assert->($public =~ /if \(my \$handler = \$command_map\{\$cmd\}\)/,
        'legacy command_map fallback still exists after event');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    my @seen;
    $bot->events->on(public_command_observed => sub {
        my ($ctx) = @_;
        push @seen, ref($ctx);
    }, name => 'test-observer');

    my $report = $bot->emit_event_report('public_command_observed', bless({}, 'FakeCtx'));
    $assert->($report->{ran} == 1,
        'runtime emit_event_report runs registered listener');
    $assert->(@seen == 1 && $seen[0] eq 'FakeCtx',
        'runtime listener receives event payload');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
