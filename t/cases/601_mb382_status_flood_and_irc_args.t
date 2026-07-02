# t/cases/601_mb382_status_flood_and_irc_args.t
# =============================================================================
# MB382 regression:
# - status must not emit one NOTICE per Scheduler task;
# - detailed status is bounded;
# - Net::Async::IRC message args are consumed in list context and legacy
#   ARRAY-ref test doubles remain compatible.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_mb382 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb382 {
    my ($src, $name) = @_;

    return undef unless $src =~ /^sub\s+\Q$name\E\s*\{/mg;

    my $begin = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';

        if ($depth == 0) {
            return substr($src, $begin, $pos + 1 - $begin);
        }

        $pos++;
    }

    return undef;
}

{
    package MB382::ListMessage;
    sub new  { bless {}, shift }
    sub args { return ('1', 'Excess Flood') }
}

{
    package MB382::ArrayRefMessage;
    sub new  { bless {}, shift }
    sub args { return ['legacy', 'arrayref'] }
}

{
    package MB382::BrokenMessage;
    sub new  { bless {}, shift }
    sub args { die "broken args accessor\n" }
}

return sub {
    my ($assert) = @_;

    my $main = _slurp_mb382(File::Spec->catfile('.', 'mediabot.pl'));
    my $admin = _slurp_mb382(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $args_sub = _extract_sub_mb382($main, '_irc_message_args');
    $assert->ok(defined $args_sub, 'shared IRC message-args helper exists');

    my $args_eval = eval "package MB382::ArgsHarness; $args_sub; 1;";
    $assert->ok($args_eval, 'IRC message-args helper compiles in isolation');

    my @list_args = MB382::ArgsHarness::_irc_message_args(
        MB382::ListMessage->new
    );
    $assert->is(scalar(@list_args), 2, 'list-returning args method keeps both arguments');
    $assert->is($list_args[0], '1', 'numeric-looking first argument remains data');
    $assert->is($list_args[1], 'Excess Flood', 'server ERROR text remains available');

    my @legacy_args = MB382::ArgsHarness::_irc_message_args(
        MB382::ArrayRefMessage->new
    );
    $assert->is(scalar(@legacy_args), 2, 'legacy ARRAY-ref result keeps both arguments');
    $assert->is($legacy_args[0], 'legacy', 'legacy first argument is preserved');
    $assert->is($legacy_args[1], 'arrayref', 'legacy second argument is preserved');

    my @broken_args = MB382::ArgsHarness::_irc_message_args(
        MB382::BrokenMessage->new
    );
    $assert->is(scalar(@broken_args), 0, 'broken args accessor fails closed');

    my $raw_args_calls = () = $main =~ /\$message->args/g;
    $assert->is($raw_args_calls, 1, 'only the compatibility helper calls message->args directly');
    $assert->unlike(
        $main,
        qr/\@\{\s*\$message->args/,
        'no callback dereferences message args in scalar context'
    );
    $assert->unlike(
        $main,
        qr/\$message->args\s*->\s*\[/,
        'no callback treats message args as an ARRAY reference'
    );

    my $error_body = _extract_sub_mb382($main, 'on_message_ERROR');
    $assert->like(
        $error_body // '',
        qr/my \@error_args = _irc_message_args\(\$message\)/,
        'ERROR callback uses the shared list-context helper'
    );
    $assert->like(
        $error_body // '',
        qr/IRC connection closed/,
        'ERROR callback has a defensive empty-message fallback'
    );

    my $pack_sub = _extract_sub_mb382(
        $admin,
        '_status_scheduler_detail_lines'
    );
    $assert->ok(defined $pack_sub, 'bounded Scheduler detail packer exists');

    my $pack_eval = eval "package MB382::StatusHarness; $pack_sub; 1;";
    $assert->ok($pack_eval, 'Scheduler detail packer compiles in isolation');

    my @tasks = map {
        {
            name      => sprintf('task_%02d_with_a_descriptive_name', $_),
            interval  => 60 * $_,
            started   => 1,
            ticks     => $_ - 1,
            last_tick => 0,
        }
    } 1 .. 12;

    my @detail_lines = MB382::StatusHarness::_status_scheduler_detail_lines(
        \@tasks,
        now       => 1000,
        max_lines => 3,
        max_chars => 350,
    );

    $assert->ok(@detail_lines >= 1, 'detailed Scheduler output is produced');
    $assert->ok(@detail_lines <= 3, 'detailed Scheduler output is capped at three lines');

    for my $line (@detail_lines) {
        $assert->ok(length($line) <= 350, 'each detailed Scheduler line stays within its bound');
    }

    my $details_joined = join(' ', @detail_lines);
    $assert->like($details_joined, qr/task_01_with_a_descriptive_name/, 'first task is represented');
    $assert->like(
        $details_joined,
        qr/task_12_with_a_descriptive_name|\+\d+ more/,
        'last task is represented or omission is reported explicitly'
    );

    my $status_body = _extract_sub_mb382($admin, 'mbStatus_ctx');
    $assert->like(
        $status_body // '',
        qr/my \$status_mode = lc\(\$args->\[0\] \/\/ ''\)/,
        'status reads its optional detail mode from Context args'
    );
    $assert->like(
        $status_body // '',
        qr/details: status full/,
        'normal status advertises the explicit detailed mode'
    );
    $assert->like(
        $status_body // '',
        qr/max_lines => 3/,
        'status full caps Scheduler details at three extra lines'
    );
    $assert->unlike(
        $status_body // '',
        qr/for my \$t .*?botNotice/s,
        'status no longer sends one NOTICE per Scheduler task'
    );
    $assert->unlike(
        $status_body // '',
        qr/—/,
        'status output uses ASCII separators and avoids mojibake-prone punctuation'
    );
    $assert->like(
        $status_body // '',
        qr/RAM RSS \$\{rss\}MB, VM \$\{vm\}MB/,
        'memory data is folded into the compact first line'
    );
    $assert->like(
        $status_body // '',
        qr/Server: \$uname \| uptime \$server_uptime/,
        'server identity and uptime share one compact line'
    );
    $assert->like(
        $admin,
        qr/mb382-B2/,
        'MB382 status marker is present'
    );
    $assert->like(
        $main,
        qr/mb382-B1/,
        'MB382 IRC args marker is present'
    );
};
