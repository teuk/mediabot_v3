package Mediabot::Partyline::ShellContext;
use strict;
use warnings;
use Mediabot::Diagnostics::Channel ();

# The shell selects a cached database channel identity. It never borrows
# configuration hashes, IRC keys, plugin storage or an arbitrary dump API.
sub _error { die bless {public => $_[0]}, __PACKAGE__.'::Usage' }
sub _number { defined($_[0]) && !ref($_[0]) && "$_[0]" =~ /\A[1-9][0-9]{0,15}\z/ }

sub channels {
    my ($class, $bot) = @_;
    my $cache = $bot->{channels};
    _error('Channel cache unavailable.') unless ref($cache) eq 'HASH';
    my @rows;
    for my $key (sort keys %$cache) {
        my $object = $cache->{$key};
        next unless ref($object);
        my $name = eval { $object->get_name };
        $name = Mediabot::Diagnostics::Channel::channel_text($name);
        my $id = eval { $object->get_id };
        next unless defined($name) && _number($id);
        push @rows, {name => $name, channel_id => "$id"};
    }
    return @rows;
}

sub select {
    my ($class, $bot, $requested) = @_;
    $requested = Mediabot::Diagnostics::Channel::channel_text($requested);
    _error('Usage: use #channel or use - (global context).') unless defined $requested;
    my @matches = grep {lc($_->{name}) eq lc($requested)} $class->channels($bot);
    _error('Channel is not in the registered cache. Use channels.') unless @matches;
    _error('Ambiguous cached channel identity.') unless @matches == 1;
    return {%{$matches[0]}};
}

sub current {
    my ($class, $bot, $state) = @_;
    _error('Select a channel first: use #channel.') unless defined $state->{channel};
    my $row = $class->select($bot, $state->{channel});
    _error('Channel identity changed. Select it again with use #channel.')
        unless $row->{channel_id} eq $state->{channel_id};
    return $row;
}

sub details {
    my ($class, $bot, $state) = @_;
    my $row = $class->current($bot, $state);
    my ($object) = grep {
        ref($_) && eval {$_->get_id eq $row->{channel_id}
            && lc($_->get_name) eq lc($row->{name})}
    } values %{$bot->{channels}};
    _error('Channel cache unavailable.') unless $object;
    # Whitelist scalar getters only; get_key/get_chanmode are intentionally absent.
    for my $field ([timezone => 'get_timezone'], [topic => 'get_topic'],
                   [description => 'get_description']) {
        my $method = $field->[1];
        my $value = $object->$method();
        $row->{$field->[0]} = $value if defined($value) && !ref($value);
    }
    my $runtime = $bot->{wit_runtime_state}
        ? $bot->{wit_runtime_state}->snapshot($row->{name}) : undef;
    $row->{joined} = ref($runtime) eq 'HASH' && defined($runtime->{channel_joined})
        && !ref($runtime->{channel_joined}) && "$runtime->{channel_joined}" =~ /\A[01]\z/
        ? ($runtime->{channel_joined} ? 'yes' : 'no') : 'unknown';
    return $row;
}

sub nicks {
    my ($class, $bot, $state) = @_;
    my $row = $class->current($bot, $state);
    my @nicks = $bot->gethChannelsNicksOnChan($row->{name});
    my %seen;
    return sort {lc($a) cmp lc($b)} grep {
        defined($_) && !ref($_) && length($_) && !$seen{lc($_)}++
    } @nicks;
}

sub plugins {
    my ($class, $bot, $state) = @_;
    my $row = $class->current($bot, $state);
    _error('Plugin observations unavailable.') unless $bot->{plugin_manager};
    my $report = $bot->{plugin_manager}->channel_diagnostic_snapshot($row->{name});
    _error('Plugin observations unavailable.') unless ref($report) eq 'HASH'
        && ref($report->{packages}) eq 'ARRAY';
    return $report;
}

sub diagnosis {
    my ($class, $bot, $state) = @_;
    my $row = $class->current($bot, $state);
    my $diagnostic = Mediabot::Diagnostics::Channel->new(bot => $bot);
    my $report = $diagnostic->collect($row->{name});
    _error('Database channel identity changed. Refresh the channel cache and reselect.')
        if defined($report->{channel_id}) &&
            ("$report->{channel_id}" ne $row->{channel_id}
                || lc($report->{channel}) ne lc($row->{name}));
    return ($diagnostic, $report);
}
1;
