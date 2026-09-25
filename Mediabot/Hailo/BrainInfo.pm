package Mediabot::Hailo::BrainInfo;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(brain_info brain_report save_existing hailo_command);

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

    return { ok => 1, text => "$prefix state=absent", state => 'absent' }
        unless -f $path;

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
    return {
        ok => 1, text => "$prefix state=ready bytes=$bytes " . _stats(@raw),
        state => 'ready', bytes => $bytes,
        counters => { map { $_ => _count(shift @raw) }
            qw(tokens expressions previous_links next_links) },
    };
}

sub _number {
    my ($value) = @_;
    return 'inconnu' if !defined($value) || $value eq 'unknown';
    $value =~ s/(?<=\d)(?=(?:\d{3})+\z)/ /g;
    return $value;
}

sub _size {
    my ($bytes) = @_;
    return 'taille inconnue' if !defined($bytes) || $bytes eq 'unknown';
    return _number($bytes) . ' octets' if $bytes < 1024;
    return sprintf('%.2f Mio sur disque', $bytes / 1048576)
        if $bytes >= 1048576;
    return sprintf('%.1f Kio sur disque', $bytes / 1024);
}

sub _percent {
    my ($value) = @_;
    return undef unless defined($value) && !ref($value)
        && "$value" =~ /\A(?:0|[1-9][0-9]{0,2})\z/ && $value <= 100;
    return "$value%";
}

# Use Mediabot's existing IRC accents (radio orange, numeric cyan, status
# green/red/amber). Foreground only, with a reset after each highlight so
# clients with either light or dark backgrounds keep their own text colour.
sub _accent {
    my ($color, $value) = @_;
    return "\x03${color}\x02${value}\x02\x0f";
}

sub _label { "\x1f$_[0]\x1f" }

sub _metric {
    my ($value) = @_;
    return _accent($value eq 'inconnu' ? '08' : '11', $value);
}

# A small presentation adapter: no backend subclass, disk scan, brain mutation,
# or claim that a Hailo expression is a retained original training sentence.
# Each line fits easily in an IRC NOTICE, even with a long channel name.
sub brain_report {
    my ($channel, $info, $policy, $settings, $chatter_ratio) = @_;
    return [] unless ref($info) eq 'HASH' && $info->{ok};
    $policy = {} unless ref($policy) eq 'HASH';
    $settings = {} unless ref($settings) eq 'HASH';

    my @lines;
    my $heading = _accent('07', 'Hailo') . ' ' . _label($channel);
    if ($info->{state} eq 'absent') {
        push @lines, "$heading : " . _accent('08', 'aucun cerveau enregistré')
            . " pour ce salon. Cette consultation n'en crée pas.";
    } else {
        push @lines, "$heading : cerveau " . _accent('03', 'prêt')
            . ' (SQLite, ' . _metric(_size($info->{bytes})) . ').';
        my $c = $info->{counters} || {};
        push @lines, _label('Mon modèle') . ' compte ' . _metric(_number($c->{tokens}))
            . ' jetons et ' . _metric(_number($c->{expressions}))
            . ' expressions ; ' . _metric(_number($c->{previous_links}))
            . ' liens vers le précédent et ' . _metric(_number($c->{next_links}))
            . ' vers le suivant. Ce ne sont pas des phrases archivées.';
    }

    if (!$policy->{master}) {
        push @lines, _label('Sur ce salon') . ', Hailo est '
            . _accent('04', 'désactivé') . ' : ni apprentissage ni réponse.';
        return \@lines;
    }
    my $learning = $policy->{learn}
        ? _accent('03', 'actif') : _accent('04', 'désactivé');
    if ($policy->{learn} && defined($settings->{min_words})
            && defined($settings->{max_words})) {
        $learning .= ' (phrases de ' . $settings->{min_words}
            . ($settings->{max_words} ? ' à ' . $settings->{max_words} : ' mots ou plus')
            . ($settings->{max_words} ? ' mots' : '') . ')';
    }
    my $respond = $policy->{respond}
        ? _accent('03', 'actives') : _accent('04', 'désactivées');
    my $rate = _percent($settings->{key_reply_rate});
    $respond .= ' (' . _metric($rate) . ' avant les limites de débit)'
        if $policy->{respond} && defined $rate;
    push @lines, _label('Sur ce salon')
        . " : apprentissage $learning ; réponses aux mentions $respond.";

    my $chatter = $policy->{chatter}
        ? _accent('03', 'active') : _accent('04', 'désactivée');
    my $ratio = _percent($chatter_ratio);
    if ($policy->{chatter}) {
        $chatter = !defined($ratio)
            ? _accent('08', 'inactive') . ' (ratio non configuré ou indisponible)'
            : $chatter_ratio == 0
            ? _accent('04', 'inactive') . ' (ratio de ' . _metric($ratio) . ')'
            : _accent('03', 'active') . ' (' . _metric($ratio)
                . " de base, réduit selon l'activité du salon)";
    }
    push @lines, _label('Libre expression') . " : $chatter.";
    return \@lines;
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
    unless ($info->{ok}) {
        $ctx->reply_private("Hailo brain info unavailable: $info->{error}");
        return 0;
    }
    my $settings = eval { $bot->{hailo_policy}->operator_settings };
    my $ratio = eval { $bot->get_hailo_channel_ratio($channel) };
    $ctx->reply_private($_) for @{ brain_report($channel, $info, $policy, $settings, $ratio) };
    return 1;
}

1;
