package Mediabot::Version::Remote;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use HTTP::Tiny;
use Mediabot::AsyncWorker;
use Mediabot::Version::Format ();

our @EXPORT_OK = qw(
    _remote_version_urls
    _remote_version_timeout
    _remote_version_worker_timeout
    fetch_remote_version
    getVersion
    _version_asyncworker_reason
    getVersion_async
);

# Remote VERSION transport and its AsyncWorker adapter share one owner.
# Local VERSION path/cache ownership stays in Helpers. Preserve its optional
# runtime hooks at the point of each call, including legacy URL-list overrides.

sub _compat_remote_version_urls {
    return Mediabot::Helpers::_remote_version_urls(@_)
        if defined &Mediabot::Helpers::_remote_version_urls;
    return _remote_version_urls(@_);
}

sub _compat_remote_version_timeout {
    return Mediabot::Helpers::_remote_version_timeout(@_)
        if defined &Mediabot::Helpers::_remote_version_timeout;
    return _remote_version_timeout(@_);
}

sub _compat_remote_version_worker_timeout {
    return Mediabot::Helpers::_remote_version_worker_timeout(@_)
        if defined &Mediabot::Helpers::_remote_version_worker_timeout;
    return _remote_version_worker_timeout(@_);
}

sub _compat_fetch_remote_version {
    return Mediabot::Helpers::fetch_remote_version(@_)
        if defined &Mediabot::Helpers::fetch_remote_version;
    return fetch_remote_version(@_);
}

sub _compat_getVersion {
    return Mediabot::Helpers::getVersion(@_)
        if defined &Mediabot::Helpers::getVersion;
    return getVersion(@_);
}

sub _compat_version_asyncworker_reason {
    return Mediabot::Helpers::_version_asyncworker_reason(@_)
        if defined &Mediabot::Helpers::_version_asyncworker_reason;
    return _version_asyncworker_reason(@_);
}

sub _usable_local_version {
    return Mediabot::Helpers::_usable_local_version(@_)
        if defined &Mediabot::Helpers::_usable_local_version;
    return Mediabot::Version::Format::_usable_local_version(@_);
}

sub _version_parts {
    return Mediabot::Helpers::_version_parts(@_)
        if defined &Mediabot::Helpers::_version_parts;
    return Mediabot::Version::Format::_version_parts(@_);
}

sub _compare_mediabot_versions {
    return Mediabot::Helpers::_compare_mediabot_versions(@_)
        if defined &Mediabot::Helpers::_compare_mediabot_versions;
    return Mediabot::Version::Format::_compare_mediabot_versions(@_);
}

sub _cached_local_version {
    require Mediabot::Helpers unless defined &Mediabot::Helpers::_cached_local_version;
    return Mediabot::Helpers::_cached_local_version(@_);
}

sub getLocalVersion {
    require Mediabot::Helpers unless defined &Mediabot::Helpers::getLocalVersion;
    return Mediabot::Helpers::getLocalVersion(@_);
}

# mb638-B1: LE fetch de la version distante, et la RAISON de son echec.
#
# Terrain (#teuk) : « github: Undefined » sans un mot d'explication. La cause
# etait structurelle : getVersion journalisait bien « Failed to fetch ... HTTP
# 599 », mais getVersion_async execute getVersion dans un FILS dont le logger
# est volontairement muet (_SilentLogger, pour ne pas doubler les traces de
# demarrage). Un echec reseau devenait donc indiscernable d'une absence de
# version. On rend desormais (version, raison) : la raison traverse le tuyau
# et remonte jusqu'a l'operateur.
#
# Deux URL sont essayees : raw.githubusercontent.com, puis le miroir
# github.com/<repo>/raw/<branche>. Un seul des deux peut etre bloque par un
# pare-feu, un proxy ou une route IPv6 morte — c'est exactement le genre de
# panne qu'on ne diagnostique pas a distance.
our @VERSION_URLS = (
    'https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION',
    'https://github.com/teuk/mediabot_v3/raw/master/VERSION',
);

sub _remote_version_urls {
    my ($self) = @_;

    my $conf_url = eval { $self->{conf}->get('update.VERSION_URL') };
    if (defined $conf_url && !ref $conf_url && $conf_url =~ m{\Ahttps?://}i) {
        # mb639: VERSION_URL est un vrai override. L'operateur qui le renseigne
        # demande UNE route precise (proxy/miroir interne), pas « essaye-la puis
        # repars quand meme vers GitHub ».
        return ($conf_url);
    }

    {
        no warnings 'once';
        return @Mediabot::Helpers::VERSION_URLS
            if defined &Mediabot::Helpers::_remote_version_urls;
    }
    return @VERSION_URLS;
}

sub _remote_version_timeout {
    my ($self) = @_;

    my $timeout = eval { $self->{conf}->get('update.VERSION_TIMEOUT') };
    $timeout = 8 unless defined $timeout && !ref($timeout)
        && $timeout =~ /\A\d+\z/ && $timeout > 0;
    $timeout = 30 if $timeout > 30;
    return 0 + $timeout;
}

sub _remote_version_worker_timeout {
    my ($self) = @_;

    my @urls = _compat_remote_version_urls($self);
    my $per_url = _compat_remote_version_timeout($self);

    # mb639: le worker doit survivre a CHAQUE tentative. Avec deux URL et un
    # timeout de 8 s, l'ancien timeout externe fixe a 8 s tuait le fils au
    # moment exact ou le miroir devait prendre le relais.
    my $budget = ($per_url * (@urls || 1)) + 1;
    $budget = 65 if $budget > 65;    # 2 * 30 s + marge, borne absolue
    return $budget;
}

sub fetch_remote_version {
    my ($self) = @_;

    my @urls = _compat_remote_version_urls($self);
    my $timeout = _compat_remote_version_timeout($self);

    # HTTP::Tiny ne fait pas d'HTTPS sans IO::Socket::SSL. Ne l'exigeons que
    # lorsque la route choisie est HTTPS : un override HTTP explicite (reseau
    # de confiance/proxy interne) ne doit pas etre refuse avant meme l'essai.
    if (grep { /^https:\/\//i } @urls) {
        unless (HTTP::Tiny->can_ssl) {
            return (undef, 'HTTPS unavailable (install IO::Socket::SSL and Net::SSLeay)');
        }
    }
    # La verification des certificats suit la politique commune du bot
    # (_make_http). MB696 a revalide cette politique sur le serveur reel : TLS
    # verifie fonctionne avec GitHub et les endpoints publics utilises ici.

    my $last_error;
    for my $url (@urls) {
        # Reutiliser le client commun evite toute seconde politique TLS locale.
        # Son defaut est maintenant verify_SSL=1; les rares exceptions de
        # compatibilite doivent etre explicites a leur point d'appel.
        my $res = eval {
            require Mediabot::External;
            Mediabot::External::_make_http(
                timeout  => $timeout,
                agent    => 'mediabot-version-check/1.0 ',
                max_size => 64 * 1024,
            )->get($url);
        };
        if (!$res || !ref $res) {
            $last_error = 'request failed: ' . ($@ || 'unknown error');
            next;
        }
        unless ($res->{success}) {
            my $status = $res->{status} // '?';
            my $reason = $res->{reason} // '';
            # HTTP::Tiny met le detail de l'erreur reseau dans le corps
            # quand le statut est 599 (echec avant reponse).
            my $detail = ($status eq '599' && defined $res->{content})
                ? do { my $c = $res->{content}; $c =~ s/\s+/ /g; substr($c, 0, 120) }
                : $reason;
            $last_error = "HTTP $status" . (length($detail) ? " ($detail)" : '');
            next;
        }

        my $body = $res->{content} // '';
        $body =~ s/\A\x{FEFF}//;          # BOM eventuel
        $body =~ s/\s+\z//;
        $body =~ s/\A\s+//;
        if ($body eq '') {
            $last_error = 'empty VERSION file';
            next;
        }
        if (length($body) > 256 || $body =~ /[\r\n]/ || !_version_parts($body)) {
            # Un HTTP 200 ne suffit pas : une page HTML courte sur UNE ligne,
            # un message de proxy ou n'importe quel texte arbitraire ne doit
            # jamais devenir une version distante.
            $last_error = 'unexpected content (not a VERSION file)';
            next;
        }
        return ($body, undef);
    }

    return (undef, $last_error // 'no URL could be reached');
}

sub getVersion {
    my $self = shift;
    my ($local_version, $remote_version) = ("Undefined", "Undefined");
    my ($c_major, $c_minor, $c_type, $c_dev_info);
    my ($r_major, $r_minor, $r_type, $r_dev_info);

    # mb639: chaque check part avec une raison vierge. Sinon un ancien HTTP 599
    # pouvait survivre dans l'objet et etre rapporte au check suivant alors que
    # la version locale etait devenue illisible et qu'aucun fetch n'avait eu lieu.
    $self->{_version_fetch_error} = undef if ref($self);

    # MB389: explicit remote checks reuse the same local-only identity helper
    # used by startup, then perform GitHub I/O only for the remote half.
    $local_version = getLocalVersion($self);
    if ($local_version ne 'Undefined') {
        ($c_major, $c_minor, $c_type, $c_dev_info) = $self->getDetailedVersion($local_version);
    }

    if (defined $c_major && defined $c_minor && defined $c_type) {
        my $suffix = $c_dev_info ? "($c_dev_info)" : '';
        $self->{logger}->log(1, "-> Mediabot $c_type version $c_major.$c_minor $suffix");
    } else {
        $self->{logger}->log(1, "-> Unknown local version format: $local_version");
    }

    # If we have a valid local version, try fetching the GitHub version
    if ($local_version ne "Undefined") {
        $self->{logger}->log(1, "Checking latest version from GitHub...");

        # mb638-B1: un seul fetch pour tout le bot, et sa raison d'echec.
        my ($fetched, $fetch_error) = _compat_fetch_remote_version($self);
        my $response = { success => (defined $fetched ? 1 : 0),
                         status  => (defined $fetched ? 200 : 599),
                         reason  => $fetch_error };

        if ($response->{success}) {
            $remote_version = $fetched;
            $self->{_version_fetch_error} = undef;

            ($r_major, $r_minor, $r_type, $r_dev_info) = $self->getDetailedVersion($remote_version);

            if (defined $r_major && defined $r_minor && defined $r_type) {
                my $suffix = $r_dev_info ? "($r_dev_info)" : '';
                $self->{logger}->log(1, "-> GitHub $r_type version $r_major.$r_minor $suffix");

                my $comparison = _compare_mediabot_versions(
                    $local_version,
                    $remote_version,
                );

                if (!defined $comparison) {
                    $self->{logger}->log(1, "Unable to compare local and GitHub version formats.");
                }
                elsif ($comparison == 0) {
                    $self->{logger}->log(1, "Mediabot is up to date.");
                }
                elsif ($comparison < 0) {
                    $self->{logger}->log(1, "Update available: $r_type version $r_major.$r_minor $suffix");
                }
                else {
                    $self->{logger}->log(1, "Local Mediabot build is newer than GitHub: $local_version > $remote_version");
                }
            } else {
                $self->{logger}->log(1, "Unknown remote version format: $remote_version");
            }
        } else {
            $self->{_version_fetch_error} = $fetch_error;
            $self->{logger}->log(1,
                "Failed to fetch version from GitHub: " . ($fetch_error // 'unknown'));
        }
    }

    # Never replace a valid cached runtime version with an error sentinel.
    $self->{main_prog_version} = $local_version
        if _usable_local_version($local_version);

    return ($local_version, $remote_version);
}

{
    package Mediabot::Helpers::_SilentLogger;
    sub log { return 1 }
}

# MB317: the public `version` command must not perform GitHub/DNS I/O inside
# the IRC callback. Keep getVersion() synchronous for startup and explicit
# callers, but expose a child-backed asynchronous wrapper for runtime commands.

sub _version_asyncworker_reason {
    my ($result) = @_;

    return 'version check worker returned an invalid result'
        unless ref($result) eq 'HASH';

    my $error  = $result->{error} // '';
    my $stage  = $result->{stage} // '';
    my $detail = $result->{detail};
    $detail = '' if !defined($detail) || ref($detail);
    $detail =~ s/[\r\n\0]+/ /g;
    $detail =~ s/\s{2,}/ /g;
    $detail =~ s/^\s+|\s+$//g;
    $detail = substr($detail, 0, 150);

    return 'version check timed out'
        if $error eq 'worker_timeout';

    if ($error eq 'worker_signal') {
        my $signal = $result->{signal};
        return "version check worker terminated by signal $signal"
            if defined($signal) && $signal =~ /\A\d+\z/ && $signal > 0;
        return 'version check worker terminated by signal';
    }

    if ($error eq 'worker_exit') {
        my $exit = $result->{exit};
        return "version check worker exited with status $exit"
            if defined($exit) && $exit =~ /\A\d+\z/;
        return 'version check worker exited with non-zero status';
    }

    return 'version check worker produced no result'
        if $error eq 'worker_empty';

    return 'version check worker returned an invalid result'
        if $error eq 'worker_decode'
        || $error eq 'worker_encode'
        || $error eq 'worker_output_limit';

    if ($error eq 'worker_setup') {
        my $suffix = length($detail) ? ": $detail" : '';
        return "version check worker pipe failed$suffix"
            if $stage eq 'pipe';
        return "version check worker could not start$suffix"
            if $stage eq 'fork';
        return "version check worker setup failed$suffix";
    }

    return 'version check worker finalization timed out'
        if $error eq 'worker_liveness';

    return 'version check worker cancelled'
        if $error eq 'worker_cancelled';

    if ($error eq 'worker_exception') {
        my $suffix = length($detail) ? ": $detail" : '';
        return "version check crashed$suffix";
    }

    my $suffix = length($detail) ? ": $detail" : '';
    return "version check worker failed$suffix";
}

sub getVersion_async {
    my ($self, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    # Preserve the last known local identity across every worker failure path.
    my $fallback_local = _cached_local_version($self);

    my $timeout = $opts{timeout};
    $timeout = _compat_remote_version_worker_timeout($self)
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 65  if $timeout > 65;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    # Compatibility path for startup tests or callers without IO::Async.
    # It intentionally keeps the historical synchronous behavior only when
    # no usable event loop exists.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my ($local, $remote) = eval { _compat_getVersion($self) };
        my $died = $@;
        if (defined $died && $died =~ /\S/) {
            $died =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
            $died =~ s/\s+/ /g;
            $self->{_version_fetch_error} = 'version check crashed: '
                . substr($died, 0, 160);
        }
        $local  = _usable_local_version($local)
            // _usable_local_version($fallback_local)
            // 'Undefined';
        $remote = _usable_local_version($remote) // 'Undefined';
        eval { $callback->($local, $remote, $self->{_version_fetch_error}); 1; };
        return 1;
    }

    # MB652: the shared AsyncWorker owns pipe/fork, process collection,
    # timeout escalation, bounded JSON transport and callback-once semantics.
    # The version checker keeps only version-specific policy and wording.
    my $adapter_done = 0;
    my $done = sub {
        my ($result) = @_;
        return if $adapter_done;
        $adapter_done = 1;

        my ($local, $remote) = (
            _usable_local_version($fallback_local) // 'Undefined',
            'Undefined',
        );
        my $reason;

        if (ref($result) eq 'HASH' && $result->{ok}) {
            my $value = $result->{value};
            if (ref($value) ne 'ARRAY' || @$value < 2) {
                $reason = 'version check worker returned an invalid result';
            }
            else {
                my ($candidate_local, $candidate_remote) = @$value[0, 1];
                my $why = $value->[2];

                my $usable_local  = _usable_local_version($candidate_local);
                my $usable_remote = _usable_local_version($candidate_remote);

                $local = $usable_local
                    if defined($usable_local) && length($usable_local) <= 256;
                $remote = $usable_remote
                    if defined($usable_remote) && length($usable_remote) <= 256;

                $reason = $why
                    if defined($why) && !ref($why) && length($why);
            }
        }
        else {
            $reason = _compat_version_asyncworker_reason($result);
        }

        # mb638-B1: 3e argument = pourquoi le distant manque (undef si tout va
        # bien). Les appelants historiques qui n'en veulent pas l'ignorent.
        my $callback_ok = eval { $callback->($local, $remote, $reason); 1; };
        if (!$callback_ok && $self && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "getVersion_async callback failed: $error");
        }
    };

    my $worker;
    my $launch_ok = eval {
        $worker = Mediabot::AsyncWorker->start(
            loop        => $loop,
            label       => 'version check',
            timeout     => $timeout,
            term_grace  => 0.2,
            force_grace => 2,
            max_output  => 1024,
            child       => sub {
            # Suppress duplicate version logs from the forked worker. The
            # shared worker exits via POSIX::_exit(), so inherited bot/DB/IRC
            # destructors are not run by the child.
            local $self->{logger} = bless {}, 'Mediabot::Helpers::_SilentLogger';

            # mb640-B1: an exception from getVersion is data, not silence.
            my ($local, $remote) = eval { _compat_getVersion($self) };
            my $died = $@;
            if (defined $died && $died =~ /\S/) {
                $died =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
                $died =~ s/\s+/ /g;
                $self->{_version_fetch_error} = 'version check crashed: '
                    . substr($died, 0, 160);
            }

            $local  = _usable_local_version($local)
                // _usable_local_version($fallback_local)
                // 'Undefined';
            $remote = _usable_local_version($remote) // 'Undefined';
            $local  = substr($local,  0, 256);
            $remote = substr($remote, 0, 256);

            my $why = $self->{_version_fetch_error};
            $why = substr("$why", 0, 200)
                if defined($why) && !ref($why);

            return [$local, $remote, $why];
            },
            on_done => $done,
        );
        1;
    };

    # AsyncWorker normally turns every setup problem into a structured
    # completion. Keep a final adapter-level guard so an unexpected launcher
    # exception or a contract violation can never make the version check die
    # or disappear silently.
    if (!$launch_ok && !$adapter_done) {
        my $error = $@ || 'unknown AsyncWorker launch failure';
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => $error,
        });
    }
    elsif (!$worker && !$adapter_done) {
        $done->({
            ok     => 0,
            error  => 'worker_setup',
            stage  => 'launcher',
            detail => 'AsyncWorker refused launch without a completion result',
        });
    }

    # AsyncWorker reports setup failures through on_done as well, preserving
    # the historical "started/handled" contract expected by update callers.
    return 1;
}
# getDetailedVersion remains with the Format/Helpers compatibility API.

sub _default_version_urls { return @VERSION_URLS; }

1;
