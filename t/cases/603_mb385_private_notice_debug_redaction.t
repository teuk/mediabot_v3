# t/cases/603_mb385_private_notice_debug_redaction.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _slurp_mb385 {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_between_mb385 {
    my ($src, $start, $next) = @_;
    return $1 if $src =~ /(sub\s+\Q$start\E\s*\{.*?)(?=\nsub\s+\Q$next\E\s*\{)/s;
    return;
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $src = _slurp_mb385($helpers_file);

    my $is_channel = _extract_between_mb385(
        $src, '_is_irc_channel_target', '_redact_irc_service_secret_for_log'
    );
    my $redact = _extract_between_mb385(
        $src, '_redact_irc_service_secret_for_log', '_split_text_for_irc'
    );
    my $split = _extract_between_mb385(
        $src, '_split_text_for_irc', 'botPrivmsg'
    );
    my $notice = _extract_between_mb385(
        $src, 'botNotice', 'joinChannel'
    );

    $assert->(defined($is_channel), 'channel-target helper extracted');
    $assert->(defined($redact), 'outbound redaction helper extracted');
    $assert->(defined($split), 'IRC byte splitter extracted');
    $assert->(defined($notice), 'botNotice extracted');
    return unless defined($is_channel) && defined($redact)
        && defined($split) && defined($notice);

    my $ok = eval qq{
        package MB385::Harness;
        use strict;
        use warnings;
        use Encode qw(encode);
        our \@ACTION_LOGS;
        sub logBotAction { push \@ACTION_LOGS, [\@_]; return 1; }
        $is_channel
        $redact
        $split
        $notice
        1;
    };
    $assert->($ok, 'helpers and botNotice compile in isolated harness');
    return unless $ok;

    {
        package MB385::Logger;
        sub new { bless { rows => [] }, shift }
        sub log { my ($self, $level, $text) = @_; push @{ $self->{rows} }, [$level, $text]; 1 }
    }
    {
        package MB385::IRC;
        sub new { bless { sent => [] }, shift }
        sub nick_folded { 'mediabot' }
        sub do_NOTICE {
            my ($self, %args) = @_;
            push @{ $self->{sent} }, { %args };
            return 1;
        }
    }
    {
        package MB385::Metrics;
        sub new { bless { inc => [] }, shift }
        sub inc { my ($self, @args) = @_; push @{ $self->{inc} }, \@args; 1 }
    }

    my $logger  = MB385::Logger->new;
    my $irc     = MB385::IRC->new;
    my $metrics = MB385::Metrics->new;
    my $bot = bless {
        logger  => $logger,
        irc     => $irc,
        metrics => $metrics,
    }, 'MB385::Bot';

    my $secret = 'SWORD-FISH-PRIVATE-385';
    my $account = 'account-' . ('x' x 430);
    my $wire_text = "identify $account $secret";

    MB385::Harness::botNotice($bot, 'NickServ', $wire_text);

    my $all_logs = join("\n", map { $_->[1] // '' } @{ $logger->{rows} });
    my $wire = join('', map { $_->{text} // '' } @{ $irc->{sent} });

    $assert->($wire eq $wire_text,
        'private NOTICE wire payload is unchanged across chunks');
    $assert->(index($all_logs, $secret) < 0,
        'private NOTICE secret is absent from every log level');
    $assert->(index($all_logs, '****') >= 0,
        'private NOTICE logs contain the redaction marker');
    $assert->(scalar(@{ $irc->{sent} }) > 1,
        'long private NOTICE is split on the wire');
    $assert->(
        !grep({ ($_->[0] // -1) == 4 && index($_->[1] // '', $secret) >= 0 } @{ $logger->{rows} }),
        'level-4 diagnostic never contains the private secret'
    );

    my $normal_logger = MB385::Logger->new;
    my $normal_irc = MB385::IRC->new;
    my $normal_bot = bless {
        logger  => $normal_logger,
        irc     => $normal_irc,
        metrics => MB385::Metrics->new,
    }, 'MB385::Bot';

    MB385::Harness::botNotice($normal_bot, 'Te[u]K', 'ordinary private reply');
    my $normal_logs = join("\n", map { $_->[1] // '' } @{ $normal_logger->{rows} });
    $assert->(index($normal_logs, 'ordinary private reply') >= 0,
        'ordinary private NOTICE visibility is preserved');

    my $channel_logger = MB385::Logger->new;
    my $channel_irc = MB385::IRC->new;
    my $channel_bot = bless {
        logger  => $channel_logger,
        irc     => $channel_irc,
        metrics => MB385::Metrics->new,
    }, 'MB385::Bot';

    @MB385::Harness::ACTION_LOGS = ();
    MB385::Harness::botNotice($channel_bot, '#teuk', 'identify public-demo-value');
    my $channel_logs = join("\n", map { $_->[1] // '' } @{ $channel_logger->{rows} });
    $assert->(index($channel_logs, 'identify public-demo-value') >= 0,
        'channel NOTICE logs retain visible channel text');
    $assert->(scalar(@MB385::Harness::ACTION_LOGS) == 1,
        'channel NOTICE action logging remains active');

    $assert->($notice =~ /mb385-B1/,
        'botNotice contains the MB385 marker');
    $assert->($notice !~ /text='\$text'/,
        'raw private text is absent from the initial debug statement');
    $assert->($notice =~ /_split_text_for_irc\(\$safe_log_text, 400\)/,
        'private log splitting happens after complete-message redaction');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
