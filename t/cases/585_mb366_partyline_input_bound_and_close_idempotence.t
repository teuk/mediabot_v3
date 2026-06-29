# t/cases/585_mb366_partyline_input_bound_and_close_idempotence.t
#
# mb366 — borne commune des lignes Telnet/DCC et fermeture idempotente des
# sessions Partyline.

use strict;
use warnings;
use utf8;

BEGIN {
    for my $module (
        ['IO/Async/Listener.pm',        'IO::Async::Listener'],
        ['IO/Async/Stream.pm',          'IO::Async::Stream'],
        ['IO/Async/Timer/Countdown.pm', 'IO::Async::Timer::Countdown'],
    ) {
        my ($file, $package) = @$module;
        next if $INC{$file};
        eval "package $package; sub new { my (\$class, \%args) = \@_; bless { \%args }, \$class } 1;"
            or die $@;
        $INC{$file} = __FILE__;
    }

    unless ($INC{'JSON.pm'}) {
        eval q{
            package JSON;
            require Exporter;
            our @ISA       = qw(Exporter);
            our @EXPORT_OK = qw(encode_json);
            our @EXPORT    = qw(encode_json);
            sub encode_json {
                require JSON::PP;
                return JSON::PP::encode_json($_[0]);
            }
            1;
        } or die $@;
        $INC{'JSON.pm'} = __FILE__;
    }

    unless ($INC{'Mediabot/External.pm'}) {
        eval q{ package Mediabot::External; 1; } or die $@;
        $INC{'Mediabot/External.pm'} = __FILE__;
    }
}

use Encode qw(encode_utf8);
use FindBin qw($Bin);
use lib "$Bin/../..";
use Mediabot::Partyline;

sub _slurp_585 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

{
    package MB366::Logger;
    sub new { bless { entries => [], hooks_removed => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
    sub remove_console_hook {
        my ($self, $id) = @_;
        push @{ $self->{hooks_removed} }, $id;
        return 1;
    }
}

{
    package MB366::Metrics;
    sub new { bless { current => $_[1], adds => [] }, $_[0] }
    sub get { $_[0]{current} }
    sub add {
        my ($self, $name, $delta) = @_;
        push @{ $self->{adds} }, [$name, $delta];
        $self->{current} += $delta;
        return $self->{current};
    }
}

{
    package MB366::Stream;
    sub new { bless { writes => [], closes => 0 }, shift }
    sub write {
        my ($self, $text) = @_;
        push @{ $self->{writes} }, $text;
        return 1;
    }
    sub close_when_empty { $_[0]{closes}++; return 1 }
}

{
    package MB366::Partyline;
    our @ISA = qw(Mediabot::Partyline);
    sub _cancel_auth_timeout { $_[0]{cancelled}{$_[1]}++; return 1 }
    sub _write_runtime_status { $_[0]{status_writes}++; return 1 }
}

return sub {
    my ($assert) = @_;

    my $pl = bless {}, 'MB366::Partyline';
    $assert->is(Mediabot::Partyline::MAX_PARTYLINE_LINE_BYTES(), 4096,
        'Partyline line limit is 4096 bytes');
    $assert->ok($pl->can('_extract_input_lines'),
        'shared input-line extractor is available');
    $assert->ok($pl->can('_reject_oversized_input'),
        'shared oversized-input rejection helper is available');

    my ($bad_ref_lines, $bad_ref_long) = $pl->_extract_input_lines(undef);
    $assert->is(ref($bad_ref_lines), 'ARRAY',
        'invalid buffer reference returns an empty line array');
    $assert->is(scalar(@$bad_ref_lines), 0,
        'invalid buffer reference emits no lines');
    $assert->is($bad_ref_long, 0,
        'invalid buffer reference is not treated as an attack');

    my $partial = 'nick';
    my ($partial_lines, $partial_long) = $pl->_extract_input_lines(\$partial);
    $assert->is(scalar(@$partial_lines), 0,
        'short unterminated input remains buffered');
    $assert->is($partial, 'nick',
        'short partial buffer is preserved');
    $assert->is($partial_long, 0,
        'short partial buffer is accepted');

    my $multi = "first\r\nsecond\nremain";
    my ($multi_lines, $multi_long) = $pl->_extract_input_lines(\$multi);
    $assert->is(join('|', @$multi_lines), 'first|second',
        'CRLF and LF lines are extracted in order');
    $assert->is($multi, 'remain',
        'unterminated remainder is preserved after complete lines');
    $assert->is($multi_long, 0,
        'several normal lines in one read are accepted');

    my $exact = ('x' x 4096) . "\r\n";
    my ($exact_lines, $exact_long) = $pl->_extract_input_lines(\$exact);
    $assert->is(length($exact_lines->[0]), 4096,
        'a complete line exactly at the limit is accepted');
    $assert->is($exact, '',
        'accepted complete line is consumed');
    $assert->is($exact_long, 0,
        'exact complete boundary is not rejected');

    my $pending_cr = ('y' x 4096) . "\r";
    my ($pending_lines, $pending_long) = $pl->_extract_input_lines(\$pending_cr);
    $assert->is(scalar(@$pending_lines), 0,
        'boundary line awaiting LF remains buffered');
    $assert->is(length($pending_cr), 4097,
        'one framing CR is allowed after 4096 content bytes');
    $assert->is($pending_long, 0,
        'pending CRLF boundary is accepted');

    my $oversized_complete = ('z' x 4097) . "\n";
    my ($over_lines, $over_long) = $pl->_extract_input_lines(\$oversized_complete);
    $assert->is(scalar(@$over_lines), 0,
        'oversized complete line is never dispatched');
    $assert->is($over_long, 1,
        'oversized complete line is rejected');
    $assert->is($oversized_complete, '',
        'oversized complete buffer is cleared');

    my $oversized_partial = 'q' x 4097;
    my ($over_partial_lines, $over_partial_long) = $pl->_extract_input_lines(\$oversized_partial);
    $assert->is($over_partial_long, 1,
        'unterminated line is rejected as soon as it exceeds the limit');
    $assert->is($oversized_partial, '',
        'oversized partial buffer is cleared immediately');

    my $utf8_bytes = encode_utf8('é' x 2049); # 4098 octets
    my (undef, $utf8_long) = $pl->_extract_input_lines(\$utf8_bytes);
    $assert->is($utf8_long, 1,
        'limit is measured in bytes, not Unicode characters');

    my $logger  = MB366::Logger->new;
    my $metrics = MB366::Metrics->new(2);
    my $stream  = MB366::Stream->new;
    my $live = bless {
        bot => { logger => $logger, metrics => $metrics },
        users => { 42 => { authenticated => 0 } },
        streams => { 42 => $stream },
        _eval_pending_42 => { pending => 1 },
    }, 'MB366::Partyline';

    my $reject_ok = $live->_reject_oversized_input($stream, 42, 'Partyline');
    $assert->is($reject_ok, 0,
        'oversized-input helper reports rejection');
    $assert->is($stream->{writes}[0], "Input line too long.\r\n",
        'client receives a short generic line-length error');
    $assert->is($stream->{closes}, 1,
        'oversized input schedules connection close');
    $assert->like($logger->{entries}[0][1], qr/^Partyline: input line exceeds 4096 bytes for fd=42;/,
        'server log identifies transport, boundary and fd without logging payload');
    $assert->is(scalar(@{ $metrics->{adds} }), 1,
        'first close updates the session gauge exactly once');
    $assert->is($metrics->{current}, 1,
        'first close decrements current Partyline sessions');
    $assert->ok(!exists($live->{users}{42}) && !exists($live->{streams}{42}),
        'first close removes user and stream state');
    $assert->ok(!exists($live->{_eval_pending_42}),
        'first close removes pending eval state');
    $assert->is($live->{cancelled}{42}, 1,
        'first close cancels the authentication timeout');
    $assert->is(scalar(@{ $logger->{hooks_removed} }), 1,
        'first close removes the console hook');

    my $second_close = $live->_close_session(42);
    $assert->is($second_close, 0,
        'second close of the same fd is a harmless no-op');
    $assert->is(scalar(@{ $metrics->{adds} }), 1,
        'second close does not decrement the metric again');
    $assert->is($live->{status_writes}, 1,
        'runtime status is rewritten only for the real close');

    my $src = _slurp_585("$Bin/../../Mediabot/Partyline.pm");
    $assert->like($src, qr/mb366-B1/,
        'mb366-B1 input-bound marker is present');
    $assert->like($src, qr/mb366-B2/,
        'mb366-B2 idempotent-close marker is present');
    my $extract_calls = () = $src =~ /->_extract_input_lines\(\$buffref\)/g;
    $assert->is($extract_calls, 2,
        'Telnet and DCC both use the shared bounded extractor');
    $assert->like($src, qr/_reject_oversized_input\(\$stream, \$id, 'DCC CHAT'\)/,
        'DCC path rejects oversized input through the shared helper');
    $assert->like($src, qr/_reject_oversized_input\(\$stream, \$id, 'Partyline'\)/,
        'Telnet path rejects oversized input through the shared helper');
    my $raw_line_loops = () = $src =~ /while \(\$\$buffref =~ s\/\^\(\[\^\\n\]\*\)\\n\/\/\) \{/g;
    $assert->is($raw_line_loops, 1,
        'raw line loop remains only inside the shared bounded extractor');
};
