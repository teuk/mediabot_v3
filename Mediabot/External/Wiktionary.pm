package Mediabot::External::Wiktionary;

# Source and asynchronous adaptation belong here. UserCommands retains command
# policy and imports the historical lookup names without owning worker internals.
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode ();
use Mediabot::AsyncWorker ();

our $VERSION = '1.00';
our @EXPORT_OK = qw(_define_pick_entry _define_lookup_sync _define_lookup_async);

# ---------------------------------------------------------------------------
# _define_pick_entry($data, $preferred_lang)
# Select a usable Wiktionary entry deterministically. The REST response is a
# hash keyed by language; using `values %$data` made the chosen language depend
# on Perl hash order whenever several language blocks were returned.
# ---------------------------------------------------------------------------
sub _define_pick_entry {
    my ($data, $preferred_lang) = @_;

    return unless ref($data) eq 'HASH';

    my @keys;
    if (defined($preferred_lang)
            && !ref($preferred_lang)
            && exists $data->{$preferred_lang}) {
        push @keys, $preferred_lang;
    }

    push @keys, grep {
        !defined($preferred_lang) || $_ ne $preferred_lang
    } sort keys %$data;

    for my $lang_key (@keys) {
        my $entries = $data->{$lang_key};
        next unless ref($entries) eq 'ARRAY';

        for my $entry (@$entries) {
            next unless ref($entry) eq 'HASH';

            my $definitions = $entry->{definitions};
            next unless ref($definitions) eq 'ARRAY';

            for my $definition (@$definitions) {
                next unless ref($definition) eq 'HASH';

                my $text = $definition->{definition};
                next unless defined($text) && !ref($text) && $text ne '';

                return ($entry, $text, $lang_key);
            }
        }
    }

    return;
}

# Perform the existing Wiktionary lookup synchronously. Runtime IRC commands
# call it only from _define_lookup_async(); the synchronous form remains useful
# for lightweight tests and callers without a usable IO::Async loop.
sub _define_lookup_sync {
    my ($self, $word, $lang) = @_;

    return 'define: invalid lookup.'
        unless defined($word) && !ref($word) && $word ne '';

    $lang = 'en'
        unless defined($lang) && !ref($lang) && $lang =~ /\A[a-z]{2,5}\z/;

    require URI::Escape;
    # mb436-B1: $word est en octets UTF-8. uri_escape_utf8() sur des octets
    # double-encode (café -> %C3%83%C2%A9 au lieu de %C3%A9) -> mauvaise URL.
    # On échappe directement les octets (déjà UTF-8) ; si par sécurité la chaîne
    # était en caractères (flag utf8), on la ré-encode d'abord.
    my $word_bytes = utf8::is_utf8($word) ? Encode::encode('UTF-8', $word) : $word;
    my $encoded = URI::Escape::uri_escape($word_bytes, "^A-Za-z0-9\-\._~");
    my $url = "https://$lang.wiktionary.org/api/rest_v1/page/definition/$encoded";

    my $http = Mediabot::External::_make_http(
        timeout    => 8,
        verify_SSL => 1,
        max_size   => 512 * 1024,
    );

    my $res = eval {
        $http->get($url, { headers => { Accept => 'application/json' } });
    } // { success => 0 };

    return "define: could not fetch definition for '$word'."
        unless ref($res) eq 'HASH' && $res->{success};

    require JSON;
    my $data = eval { JSON::decode_json($res->{content} // '') };

    return "define: no result for '$word'."
        if $@ || ref($data) ne 'HASH';

    my ($entry, $first_def, $entry_lang) = _define_pick_entry($data, $lang);

    return "define: no definition found for '$word' in $lang.wiktionary."
        unless $entry && defined($first_def);

    my $pos = $entry->{partOfSpeech};
    $pos = '' unless defined($pos) && !ref($pos);
    $pos =~ s/^\s+|\s+$//g;

    $first_def =~ s/<[^>]+>//g;

    require HTML::Entities;
    $first_def = HTML::Entities::decode_entities($first_def);
    $first_def =~ s/[\r\n\t]+/ /g;
    $first_def =~ s/\s{2,}/ /g;
    $first_def =~ s/^\s+|\s+$//g;
    $first_def = substr($first_def, 0, 300) . '...'
        if length($first_def) > 300;

    return "define: no definition found for '$word' in $lang.wiktionary."
        if $first_def eq '';

    $entry_lang = $lang
        unless defined($entry_lang) && !ref($entry_lang) && $entry_lang ne '';

    my $lang_tag = $entry_lang ne 'en' ? " [$entry_lang]" : '';
    my $pos_tag  = $pos ne '' ? " ($pos)" : '';

    return "$word$lang_tag$pos_tag: $first_def";
}

# Late legacy overrides remain available without loading UserCommands just to
# use this source module. The child receives an empty bot state as before.
sub _compat_define {
    return Mediabot::UserCommands::_define_lookup_sync(@_)
        if defined &Mediabot::UserCommands::_define_lookup_sync;
    return _define_lookup_sync(@_);
}

sub _define_lookup_async {
    my ($self, $word, $lang, $callback, %opts) = @_;
    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 10 unless defined($timeout) && !ref($timeout)
        && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 20 if $timeout > 20;
    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);
    my $fallback = "define: could not fetch definition for '$word'.";

    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $message = eval { _compat_define($self, $word, $lang) };
        $message = $fallback unless defined($message) && !ref($message) && $message ne '';
        eval { $callback->($message); 1 };
        return 1;
    }

    my $finished = 0;
    my $done = sub {
        my ($result) = @_;
        return if $finished++;
        my $message = $fallback;
        if (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
            my $candidate = $result->{value}{message};
            $message = $candidate if defined($candidate) && !ref($candidate)
                && $candidate ne '' && length($candidate) <= 1024;
        }
        my $run = $callback;
        undef $callback;
        my $ok = eval { $run->($message); 1 };
        if (!$ok && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            eval { $self->{logger}->log(1, "define async callback failed: $error") };
        }
    };
    my $worker = eval { Mediabot::AsyncWorker->start(
        loop => $loop, label => 'definition lookup', timeout => $timeout,
        term_grace => 0.2, force_grace => 1, max_output => 8192,
        child => sub {
            my $message = _compat_define({}, $word, $lang);
            $message = $fallback unless defined($message) && !ref($message) && $message ne '';
            return { message => substr($message, 0, 1024) };
        },
        on_done => $done,
    ) };
    $done->({ ok => 0, error => 'worker_setup' }) unless $worker;
    return 1;
}

1;
