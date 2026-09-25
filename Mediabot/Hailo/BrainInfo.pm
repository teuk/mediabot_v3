package Mediabot::Hailo::BrainInfo;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(brain_info save_existing hailo_command);

sub _count {
    my ($value) = @_;
    return 'unknown' unless defined $value && !ref $value;
    return "$value" if "$value" =~ /\A(?:0|[1-9][0-9]{0,14})\z/;
    return 'unknown';
}

sub _stats {
    my @values = @_;
    return join ' ', map { $_ . '=' . _count(shift @values) }
        qw(tokens expressions previous_links next_links);
}

# A report never contains learned lines, tokens, arbitrary backend fields or
# filesystem paths. An absent brain is not opened and thus cannot be seeded.
sub brain_info {
    my ($registry, $channel, $policy) = @_;
    return { ok => 0, error => 'Hailo brain registry unavailable' }
        unless $registry && $registry->can('brain_path_for');
    return { ok => 0, error => 'Invalid channel' }
        unless defined($channel) && !ref($channel)
            && $channel =~ /\A\#[^\s,\x00-\x1f\x7f]{1,79}\z/;

    my $path = eval { $registry->brain_path_for($channel) };
    return { ok => 0, error => 'Invalid channel' } if $@ || !defined $path;
    return { ok => 0, error => 'Unsafe brain path' } if -l $path;
    return { ok => 0, error => 'Brain path is not a regular file' }
        if -e $path && !-f $path;

    $policy = {} unless ref($policy) eq 'HASH';
    my $switches = join ' ', map {
        $_ . '=' . ($policy->{$_} ? 'on' : 'off')
    } qw(master learn respond chatter);
    my $prefix = "Hailo brain $channel: backend=SQLite $switches";

    return { ok => 1, text => "$prefix state=absent" } unless -f $path;

    my $brain = eval { $registry->brain_for($channel) };
    return { ok => 0, error => 'Brain could not be opened' }
        if $@ || !$brain || !$brain->can('stats');
    # Hailo 0.75 returns four scalars in list context, in this exact order.
    my @raw = eval { $brain->stats };
    return { ok => 0, error => 'Brain statistics unavailable' }
        if $@ || @raw != 4;

    my @st = stat($path);
    return { ok => 0, error => 'Brain file unavailable' }
        if !@st || -l $path || !-f $path;
    my $bytes = _count($st[7]);
    return { ok => 1, text => "$prefix state=ready bytes=$bytes " . _stats(@raw) };
}

# Persist only a brain that already exists on disk. Never create or seed a
# channel brain as a side effect of an operator maintenance command.
sub save_existing {
    my ($registry, $channel) = @_;
    return { ok => 0, error => 'Hailo brain registry unavailable' }
        unless $registry && $registry->can('brain_path_for');
    return { ok => 0, error => 'Invalid channel' }
        unless defined($channel) && !ref($channel)
            && $channel =~ /\A\#[^\s,\x00-\x1f\x7f]{1,79}\z/;
    my $path = eval { $registry->brain_path_for($channel) };
    return { ok => 0, error => 'Invalid channel' } if $@ || !defined $path;
    return { ok => 0, error => 'Unsafe brain path' } if -l $path;
    return { ok => 0, error => 'Brain path is not a regular file' }
        if -e $path && !-f $path;
    return { ok => 0, error => 'Brain is absent' } unless -f $path;
    my $brain = eval { $registry->brain_for($channel) };
    return { ok => 0, error => 'Brain could not be opened' }
        if $@ || !$brain || !$brain->can('save');
    my $ok = eval { $brain->save; 1 };
    return { ok => 0, error => 'Brain could not be saved' } unless $ok;
    return { ok => 0, error => 'Brain path changed during save' }
        if -l $path || !-f $path;
    return { ok => 1, text => "Hailo brain $channel saved." };
}

# The public command is registered in Mediabot's built-in catalogue, so its
# prefix comes from main.MAIN_PROG_CMD_CHAR rather than being hard-coded here.
sub hailo_command {
    my ($ctx) = @_;
    return unless $ctx->require_level('Master');
    my @args = @{ $ctx->args };
    my $action = @args ? lc($args[0]) : '';
    if ($action eq 'help' && @args == 1) {
        $ctx->reply_private('Hailo: braininfo #channel (Master), savebrain #channel (Owner). Selective forget and forgetword require a complete training corpus.');
        return 1;
    }
    unless (@args == 2 && ($action eq 'braininfo' || $action eq 'savebrain')
            && defined($args[1]) && !ref($args[1])
            && $args[1] =~ /\A\#[^\s,\x00-\x1f\x7f]{1,79}\z/) {
        $ctx->reply_private('Syntax: hailo braininfo <#channel> | hailo savebrain <#channel> | hailo help');
        return;
    }
    my $channel = $args[1];
    my $bot = $ctx->bot;
    if ($action eq 'savebrain') {
        return unless $ctx->require_level('Owner');
        my $result = save_existing($bot->{hailo_registry}, $channel);
        $ctx->reply_private($result->{ok} ? $result->{text}
            : "Hailo brain save unavailable: $result->{error}");
        return $result->{ok} ? 1 : 0;
    }
    my $policy = eval { $bot->hailo_channel_policy($channel, fresh => 1) };
    unless (ref($policy) eq 'HASH') {
        $ctx->reply_private('Hailo brain info unavailable: channel policy could not be read.');
        return;
    }
    my $info = brain_info($bot->{hailo_registry}, $channel, $policy);
    $ctx->reply_private($info->{ok} ? $info->{text}
        : "Hailo brain info unavailable: $info->{error}");
    return $info->{ok} ? 1 : 0;
}

1;
