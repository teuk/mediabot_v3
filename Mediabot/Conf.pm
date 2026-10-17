package Mediabot::Conf;

use strict;
use warnings;
use Config::Simple;
use Cwd qw(abs_path);
use Digest::SHA ();
use Fcntl qw(:DEFAULT :flock S_ISREG);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use IO::Handle ();

sub new {
    my ($class, $conf_ref, $file, %args) = @_;
    my $self = {
        _conf   => $conf_ref || {},
        _file   => $file,
        _cfg    => undef,
        _logger => $args{logger} // undef,  # optional logger object
    };

    bless $self, $class;

    # mb368-B1: initial file loading and runtime reload now share the same
    # atomic path.  The in-memory configuration is replaced only after a new
    # Config::Simple object has been created and read successfully.
    $self->reload() if $file;

    return $self;
}

sub reload {
    my ($self) = @_;

    my $file = $self->{_file};
    die "Conf->reload(): no configuration file associated with this object\n"
        unless defined($file) && length($file);
    die "Conf->reload(): configuration file '$file' does not exist\n"
        unless -e $file;
    die "Conf->reload(): configuration file '$file' is not readable\n"
        unless -r $file;

    my $before = _file_revision($file);
    my $cfg = Config::Simple->new(filename => $file);
    die "Conf->reload(): failed to parse configuration file '$file'\n"
        unless $cfg;

    my %fresh = $cfg->vars();
    my $after = _file_revision($file);
    die "Conf->reload(): configuration changed while reading; retry reload\n"
        unless _same_revision($before, $after);

    # Commit only after the complete replacement state has been prepared.
    $self->{_cfg}  = $cfg;
    $self->{_conf} = \%fresh;
    $self->{_revision} = $after;

    # A changed file may contain a different invalid/clamped value.  Let the
    # diagnostic deduplicator report the new state once after the reload.
    $self->{_get_int_diag_seen} = {};

    return 1;
}

sub get {
    my ($self, $key) = @_;
    # Warn at debug level 4 if the key doesn't exist in the conf
    # Helps diagnose missing configuration entries during development
    unless (exists $self->{_conf}{$key}) {
        if ($ENV{MEDIABOT_DEBUG_CONF}) {
            if ($self->{_logger} && $self->{_logger}->can('log')) {
                $self->{_logger}->log(4, "Conf->get(): key '$key' not found in configuration");
            } elsif (!$self->{_warned_no_logger}++) {
                # A3: emit warn only once before logger is attached to avoid STDERR flood
                warn "Conf->get(): key '$key' not found (no logger yet)\n";
            }
        }
    }
    return $self->{_conf}{$key};
}

# Return a validated integer configuration value.
# - malformed/missing values fall back to default;
# - numeric values outside the accepted range are clamped.
# mb358-B1: émet un diagnostic (dédupliqué) quand une valeur PRÉSENTE est
# malformée ou doit être clampée, pour que l'admin repère une erreur de config.
# L'absence de clé reste silencieuse ici (get() la trace déjà en debug niveau 4)
# et la dédup évite tout spam (get_int peut être appelé à chaque login/tick).
sub get_int {
    my ($self, $key, %opts) = @_;

    die("Conf->get_int(): default required for '$key'\n")
        unless exists $opts{default};

    my $default = int($opts{default});
    my $min     = exists($opts{min}) ? int($opts{min}) : undef;
    my $max     = exists($opts{max}) ? int($opts{max}) : undef;

    die("Conf->get_int(): min cannot be greater than max for '$key'\n")
        if defined($min) && defined($max) && $min > $max;

    my $raw = $self->get($key);
    return $default if !defined($raw) || ref($raw);

    (my $trimmed = $raw) =~ s/^\s+|\s+$//g;
    unless ($trimmed =~ /^[+-]?\d+$/) {
        $self->_get_int_diag("$key|bad|$trimmed", 2,
            "Conf: '$key' = '$raw' is not an integer; using default $default");
        return $default;
    }

    my $value = int($trimmed);
    if (defined($min) && $value < $min) {
        $self->_get_int_diag("$key|low|$value", 2,
            "Conf: '$key' = $value is below minimum $min; clamped to $min");
        $value = $min;
    }
    elsif (defined($max) && $value > $max) {
        $self->_get_int_diag("$key|high|$value", 2,
            "Conf: '$key' = $value is above maximum $max; clamped to $max");
        $value = $max;
    }
    return $value;
}

# mb358-B1: journalise un diagnostic get_int une seule fois par signature
# (clé|type|valeur). Reste utile (l'admin voit le problème) sans spammer les logs
# si la même valeur fautive est relue en boucle. Une valeur fautive DIFFÉRENTE
# (ou un autre type de problème) re-déclenche un log.
sub _get_int_diag {
    my ($self, $sig, $level, $msg) = @_;
    my $logger = $self->{_logger};
    return unless $logger && $logger->can('log');
    my $seen = ($self->{_get_int_diag_seen} //= {});
    return if $seen->{$sig}++;
    $logger->log($level, $msg);
    return;
}

sub set {
    my ($self, $key, $value) = @_;
    $self->{_conf}{$key} = $value;
    # Config::Simple normalizes array elements in place. Keep that operation
    # away from the caller's input and the pending public value mirror.
    $self->{_cfg}->param($key => ref($value) eq 'ARRAY' ? [@$value] : $value)
        if $self->{_cfg};
}

sub save {
    my ($self) = @_;
    return unless $self->{_cfg} and $self->{_file};

    # MB834: never let Config::Simple truncate the active configuration. A
    # stable sidecar lock serializes cooperating writers across inode swaps;
    # a revision check also rejects stale objects and observed operator edits.
    my $base = $self->{_revision};
    die "Conf->save(): reload required before saving\n" unless $base;
    my ($lock, $tmp);
    my $stage = 'revision';
    my $ok = eval {
        die unless _same_revision($base, _file_revision($self->{_file}));
        $stage = 'hardlinked configuration';
        die unless $base->{links} == 1;
        $stage = 'configuration permissions';
        die unless -w $base->{path};

        $stage = 'writer lock';
        my $lock_path = $base->{path} . '.lock';
        sysopen($lock, $lock_path, O_RDWR|O_CREAT|O_NOFOLLOW|O_NONBLOCK, 0600) or die;
        my @held = stat($lock);
        my @named = lstat($lock_path);
        die unless @held && @named && S_ISREG($held[2]) && $held[3] == 1
            && $held[0] == $named[0] && $held[1] == $named[1];
        # Nonblocking: an IRC command must not stall the event loop waiting
        # for another process. Root-side tools leave the lock usable by the
        # configuration owner on the next ordinary bot save.
        flock($lock, LOCK_EX|LOCK_NB) or die;
        _preserve_owner($lock, $base);
        chmod(0600, $lock) or die;

        $stage = 'revision';
        die unless _same_revision($base, _file_revision($self->{_file}));
        $stage = 'configuration values';
        my %values = %{$self->{_conf}};
        for my $key (keys %values) {
            die if $key =~ /[\x00\r\n]/;
            my @items = ref($values{$key}) eq 'ARRAY' ? @{$values{$key}} : ($values{$key});
            die if grep { ref($_) || (defined($_) && /[\x00\r\n]/) } @items;
        }
        $stage = 'temporary file';
        my ($fh, $name) = tempfile('.mediabot-conf-XXXXXX',
            DIR => dirname($base->{path}), UNLINK => 0);
        $tmp = $name;
        chmod(0600, $fh) or die;
        close($fh) or die;

        $stage = 'serialization';
        {
            # Use the dependency's own strict quoting only for this write.
            # Otherwise a literal comma becomes a list on the next read.
            local $Config::Simple::USEQQ = 1;
            $self->{_cfg}->write($tmp) or die;
        }
        $stage = 'temporary file sync';
        sysopen(my $completed, $tmp, O_RDWR|O_NOFOLLOW) or die;
        _preserve_owner($completed, $base);
        chmod($base->{mode}, $completed) or die;
        $completed->sync or die;
        close($completed) or die;

        my $next = _file_revision($tmp);
        $next->{path} = $base->{path};
        $stage = 'revision';
        die unless _same_revision($base, _file_revision($self->{_file}));
        $stage = 'publication';
        rename($tmp, $base->{path}) or die;
        undef $tmp;
        $self->{_revision} = $next;
        1;
    };

    # Keep diagnostics bounded: dependency exceptions can contain configuration
    # values. Pending set() values stay in memory for explicit retry or reload.
    unlink $tmp if defined($tmp) && -e $tmp;
    close $lock if defined($lock) && defined(fileno($lock));
    unless ($ok) {
        die "Conf->save(): configuration changed on disk; reload before saving\n"
            if $stage eq 'revision';
        die "Conf->save(): atomic save failed ($stage)\n";
    }
    return 1;
}

sub _file_revision {
    my ($file) = @_;
    my $path = abs_path($file);
    die "Conf: configuration path unavailable\n" unless defined $path;
    sysopen(my $fh, $path, O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        or die "Conf: configuration read failed\n";
    my @before = stat($fh);
    die "Conf: configuration is not a regular file\n"
        unless @before && S_ISREG($before[2]);
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    my @after = stat($fh);
    close($fh) or die "Conf: configuration read failed\n";
    die "Conf: configuration changed while reading\n"
        unless @after && join(':', @before[0..5,7,9,10]) eq join(':', @after[0..5,7,9,10]);
    return {path=>$path, device=>$after[0], inode=>$after[1],
        mode=>$after[2]&07777, links=>$after[3], uid=>$after[4], gid=>$after[5],
        digest=>$sha->hexdigest};
}

sub _same_revision {
    my ($left, $right) = @_;
    for my $key (qw(path device inode mode links uid gid digest)) {
        return 0 unless defined($left->{$key}) && defined($right->{$key})
            && $left->{$key} eq $right->{$key};
    }
    return 1;
}

sub _preserve_owner {
    my ($fh, $base) = @_;
    my @st = stat($fh);
    die unless @st;
    if ($st[4] != $base->{uid} || $st[5] != $base->{gid}) {
        chown($base->{uid}, $base->{gid}, $fh) or die;
    }
}

sub all {
    my ($self) = @_;
    return %{ $self->{_conf} };
}

# Attach a logger after construction (e.g. once Log object is available)
sub set_logger {
    my ($self, $logger) = @_;
    $self->{_logger} = $logger;
}

1;

__END__

=pod

=head1 NAME

Mediabot::Conf - Magic configuration wrapper for Mediabot with read/write support

=head1 SYNOPSIS

    use Mediabot::Conf;

    # Load config from file
    my $conf = Mediabot::Conf->new(undef, '/path/to/config.conf');

    # Get a value
    my $bot_name = $conf->get('main.MAIN_PROG_NAME');

    # Set a value
    $conf->set('main.MAIN_PROG_NAME', 'NewBot');

    # Save changes back to the config file
    $conf->save();

=head1 DESCRIPTION

C<Mediabot::Conf> provides a simple and unified interface for reading,
modifying, and saving configuration values for Mediabot.

It wraps L<Config::Simple> behind a clean object interface and keeps an
internal hash mirror for convenience.

=head1 METHODS

=head2 new($hashref, $file_path)

Creates a new configuration object. If a config file path is provided, it will
be read using L<Config::Simple>. All keys/values will be stored internally and
can later be written back.

=head2 reload

Atomically rereads the configuration file associated with this object.  The
current in-memory values remain untouched if the new file cannot be opened or
parsed.  Dies with a descriptive error when the object has no backing file or
the reload fails.

=head2 get($key)

Returns the value associated with C<$key>, or undef if not found.

=head2 set($key, $value)

Sets or updates a configuration value in memory. If the object was created with
a config file, the change is mirrored in the underlying C<Config::Simple>
object.

=head2 save

Atomically publishes pending changes through a private temporary file in the
target directory, with a nonblocking writer lock, pre-publication file sync and
preserved owner/group/mode. Returns true after publication. Has no effect if the
object was not constructed with a file path.

Uses scoped strict Config::Simple quoting so literal punctuation, whitespace
and list boundaries survive a reread. Physical CR/LF/NUL and nested references
are refused on save rather than published as malformed configuration.

Dies with a bounded error on failure. A changed, deleted or retargeted file
requires C<reload> followed by explicit reapplication of the intended values;
a stale object cannot silently overwrite another writer. Failure preserves
pending C<set> values in memory for retry or reload. Stable symbolic config
paths remain links; files with several hardlinks are refused on save.

The persistent sidecar C<E<lt>resolved-configE<gt>.lock> is private. Both the
configuration and its directory must permit the write. Coordinated writers use
this lock; external editors should still stop the instance first. Atomic rename
protects against partial publication, not every filesystem/power-loss scenario.

=head2 all

Returns the full configuration as a hash (not a hashref).

=head1 AUTHOR

Christophe "teuk" <teuk@teuk.org>

=head1 LICENSE

This module is part of the Mediabot project and distributed under the same license.

=cut
