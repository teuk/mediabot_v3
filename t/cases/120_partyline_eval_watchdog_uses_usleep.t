# t/cases/120_partyline_eval_watchdog_uses_usleep.t
# =============================================================================
# MB309 regression checks for Partyline .eval watchdog timing.
#
# The grace period between TERM and KILL must be asynchronous. Sleeping inside
# an IO::Async callback blocks every other IRC/partyline event.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_partyline_watchdog_mb309 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_partyline_watchdog_mb309 {
    my ($src, $sub_name) = @_;
    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $start, $pos - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_partyline_watchdog_mb309(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );
    my $body = _extract_sub_body_partyline_watchdog_mb309($src, '_cmd_eval');

    $assert->ok(defined $body, '_cmd_eval body found');
    $assert->unlike($src, qr/^use Time::HiRes qw\(usleep\);$/m,
        'Partyline.pm no longer imports usleep');
    $assert->unlike($body // '', qr/\busleep\s*\(/,
        'eval watchdog never sleeps inside the event loop');
    $assert->like($body // '', qr/kill\s+'TERM',\s*\$pid/,
        'eval watchdog sends TERM to the child');
    $assert->like($body // '', qr/delay\s*=>\s*0\.5/,
        'TERM-to-KILL grace period uses an asynchronous 500ms timer');
    $assert->like($body // '', qr/kill\s+'KILL',\s*\$pid/,
        'eval watchdog escalates to KILL when required');
};
